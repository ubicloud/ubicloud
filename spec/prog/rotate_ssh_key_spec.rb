# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RotateSshKey do
  subject(:rsk) { described_class.new(st) }

  let(:sshable) {
    Sshable.create(
      host: "test.localhost",
      raw_private_key_1: SshKey.generate.keypair
    )
  }

  let(:st) {
    Strand.create_with_id(sshable, prog: "RotateSshKey", label: "start")
  }

  describe "#start" do
    it "generates new key and hops to install" do
      expect { rsk.start }.to hop("install")
      sshable.reload
      expect(sshable.raw_private_key_2).not_to be_nil
    end
  end

  describe "#install" do
    it "installs the key and hops to retire" do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
      expect(rsk.sshable).to receive(:_cmd).with(/set -ueo pipefail\necho .* > ~\/.ssh\/authorized_keys2\n/m)
      expect { rsk.install }.to hop("retire_old_key_on_server")
    end
  end

  describe "#retire_old_key_on_server" do
    it "retires old keys on server" do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
      sess = Net::SSH::Connection::Session.allocate
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).with(/.*mv ~\/.ssh\/authorized_keys2 ~\/.ssh\/authorized_keys.*/)
      expect { rsk.retire_old_key_on_server }.to hop("retire_old_key_in_database")
    end
  end

  describe "#retire_old_key_in_database" do
    it "retires old keys on database" do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)

      expect { rsk.retire_old_key_in_database }.to hop("test_rotation")
    end

    it "fails if no record changes" do
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
