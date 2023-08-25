# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::BootstrapRhizome do
  subject(:br) {
    described_class.new(Strand.new(prog: "BootstrapRhizome",
      stack: [{sshable_id: "bogus"}]))
  }

  describe "#start" do
    before { br.strand.label = "start" }

    it "generates a keypair" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:update) do |**args|
        key = args[:raw_private_key_1]
        expect(key).to be_instance_of String
        expect(key.length).to eq 64
      end

      expect(br).to receive(:sshable).and_return(sshable)

      expect { br.start }.to hop("setup", "BootstrapRhizome")
    end
  end

  describe "#setup" do
    before { br.strand.label = "setup" }

    it "runs initializing shell wih public keys" do
      sshable = instance_double(Sshable, keys: [instance_double(SshKey, public_key: "test key")])
      expect(br).to receive(:sshable).and_return(sshable)
      expect(br).to receive(:rootish_ssh).with <<FIXTURE
set -ueo pipefail
sudo apt update && sudo apt-get -y install ruby-bundler
sudo userdel -rf rhizome || true
sudo adduser --disabled-password --gecos '' rhizome
echo 'rhizome ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-rhizome
sudo install -d -o rhizome -g rhizome -m 0700 /home/rhizome/.ssh
sudo install -o rhizome -g rhizome -m 0600 /dev/null /home/rhizome/.ssh/authorized_keys
echo test\\ key | sudo tee /home/rhizome/.ssh/authorized_keys > /dev/null
FIXTURE

      expect { br.setup }.to hop("start", "InstallRhizome")
    end

    it "exits once InstallRhizome has returned" do
      br.strand.retval = {"msg" => "installed rhizome"}
      expect { br.setup }.to exit({"msg" => "rhizome user bootstrapped and source installed"})
    end
  end

  describe "#rootish_ssh" do
    let(:sshable) {
      instance_double(Sshable, host: "127.0.0.1",
        keys: [instance_double(SshKey, private_key: "test private key")])
    }

    before do
      expect(br).to receive(:sshable).and_return(sshable).at_least(:once)
    end

    it "executes a command using root by default" do
      expect(Net::SSH).to receive(:start) do |&blk|
        sess = instance_double(Net::SSH::Connection::Session)
        expect(sess).to receive(:exec!).with("test command").and_return(
          Net::SSH::Connection::Session::StringWithExitstatus.new("it worked", 0)
        )
        blk.call sess
      end

      br.rootish_ssh("test command")
    end

    it "fails if a command fails" do
      expect(Net::SSH).to receive(:start) do |&blk|
        sess = instance_double(Net::SSH::Connection::Session)
        expect(sess).to receive(:exec!).with("failing command").and_return(
          Net::SSH::Connection::Session::StringWithExitstatus.new("it didn't work", 1)
        )
        blk.call sess
      end

      expect { br.rootish_ssh("failing command") }.to raise_error RuntimeError, "Could not bootstrap rhizome"
    end
  end
end
