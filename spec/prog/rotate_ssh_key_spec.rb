# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RotateSshKey do
  subject(:rsk) {
    described_class.new(Strand.new(prog: "RotateSshKey", stack: [{"subject_id" => sshable.id}]))
  }

  let(:keypair_1) { SshKey.generate }
  let(:keypair_2) { SshKey.generate }
  let(:sshable) {
    Sshable.create(host: "test.localhost", raw_private_key_1: keypair_1.keypair, raw_private_key_2: keypair_2.keypair)
  }
  let(:sess) { Net::SSH::Connection::Session.allocate }

  describe "#start" do
    let(:sshable) {
      Sshable.create(host: "test.localhost", raw_private_key_1: keypair_1.keypair)
    }

    it "generates new key and hops to install" do
      expect { rsk.start }.to hop("install")
      sshable.reload
      expect(sshable.raw_private_key_2).not_to be_nil
    end
  end

  describe "#install" do
    it "installs the key and hops to retire" do
      expect(rsk.sshable).to receive(:_cmd).with(/set -ueo pipefail\necho.*> ~\/.ssh\/authorized_keys2\n/m)
      expect { rsk.install }.to hop("retire_old_key_on_server")
    end
  end

  describe "#retire_old_key_on_server" do
    it "retires old keys on server" do
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).with(/.*mv ~\/.ssh\/authorized_keys2 ~\/.ssh\/authorized_keys.*/)
      expect { rsk.retire_old_key_on_server }.to hop("retire_old_key_in_database")
    end
  end

  describe "#retire_old_key_in_database" do
    it "retires old keys on database" do
      expect { rsk.retire_old_key_in_database }.to hop("test_rotation")
      sshable.reload
      expect(sshable.raw_private_key_1).to eq(keypair_2.keypair)
      expect(sshable.raw_private_key_2).to be_nil
    end

    it "fails if no record changes" do
      sshable.update(raw_private_key_2: nil)
      expect { rsk.retire_old_key_in_database }.to raise_error RuntimeError, "Unexpected number of changed records: 0"
    end
  end

  describe "#test_rotation" do
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
