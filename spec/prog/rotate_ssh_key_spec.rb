# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RotateSshKey do
  subject(:rsk) {
    described_class.new(Strand.new(prog: "RotateSshKey"))
  }

  let(:sshable) { Sshable.new(raw_private_key_1: SshKey.generate.keypair) }

  before do
    allow(rsk).to receive(:sshable).and_return(sshable)
  end

  describe "#start" do
    it "generates new key and hops to install" do
      expect(SshKey).to receive(:generate).and_return(instance_double(SshKey, keypair: "key_2"))
      expect(sshable).to receive(:update).with({raw_private_key_2: "key_2"})
      expect { rsk.start }.to hop("install")
    end
  end

  describe "#install" do
    it "installs the key and hops to retire" do
      expect(sshable).to receive(:keys).and_return([
        instance_double(SshKey, public_key: "key_1"),
        instance_double(SshKey, public_key: "key_2")
      ])
      expect(sshable).to receive(:_cmd).with("set -ueo pipefail\necho key_1'\n'key_2 > ~/.ssh/authorized_keys2\n")
      expect { rsk.install }.to hop("retire_old_key_on_server")
    end
  end

  describe "#retire_old_key_on_server" do
    it "retires old keys on server" do
      sess = Net::SSH::Connection::Session.allocate
      expect(sshable).to receive(:raw_private_key_2).and_return(SshKey.generate.keypair)
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).with(/.*mv ~\/.ssh\/authorized_keys2 ~\/.ssh\/authorized_keys.*/)
      expect { rsk.retire_old_key_on_server }.to hop("retire_old_key_in_database")
    end
  end

  describe "#retire_old_key_in_database" do
    it "retires old keys on database" do
      sshable.id = "63ce1327-ece2-8331-9b2c-6db004bfe9d6"
      sshable.raw_private_key_2 = SshKey.generate.keypair
      sshable.save_changes

      expect { rsk.retire_old_key_in_database }.to hop("test_rotation")
    end

    it "fails if no record changes" do
      sshable.id = "63ce1327-ece2-8331-9b2c-6db004bfe9d6"
      sshable.save_changes

      expect { rsk.retire_old_key_in_database }.to raise_error RuntimeError, "Unexpected number of changed records: 0"
    end
  end

  describe "#test_rotation" do
    let(:sess) { Net::SSH::Connection::Session.allocate }

    before do
      expect(Net::SSH).to receive(:start).and_yield(sess)
    end

    it "can connect with new key" do
      expect(sess).to receive(:_exec!).with("echo key rotated successfully").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("key rotated successfully\n", 0)
      )
      expect { rsk.test_rotation }.to exit({"msg" => "key rotated successfully"})
    end

    it "fails if exit status not zero" do
      expect(sess).to receive(:_exec!).with("echo key rotated successfully").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("unknown error", 1)
      )
      expect { rsk.test_rotation }.to raise_error RuntimeError, "Unexpected exit status: 1"
    end

    it "fails if output not expected" do
      expect(sess).to receive(:_exec!).with("echo key rotated successfully").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("wrong output", 0)
      )
      expect { rsk.test_rotation }.to raise_error RuntimeError, "Unexpected output message: wrong output"
    end
  end
end
