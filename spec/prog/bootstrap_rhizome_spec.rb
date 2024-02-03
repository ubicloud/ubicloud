# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::BootstrapRhizome do
  subject(:br) {
    described_class.new(Strand.new(prog: "BootstrapRhizome", stack: [{"target_folder" => "host"}]))
  }

  describe "#start" do
    before { br.strand.label = "start" }

    it "generates a keypair" do
      sshable = instance_double(Sshable, raw_private_key_1: nil)
      expect(sshable).to receive(:update) do |**args|
        key = args[:raw_private_key_1]
        expect(key).to be_instance_of String
        expect(key.length).to eq 64
      end

      expect(br).to receive(:sshable).and_return(sshable).twice

      expect { br.start }.to hop("setup", "BootstrapRhizome")
    end

    it "does not generate a keypair if there is already one" do
      sshable = instance_double(Sshable, raw_private_key_1: "bogus")
      expect(sshable).not_to receive(:update)
      expect(br).to receive(:sshable).and_return(sshable)
      expect { br.start }.to hop("setup", "BootstrapRhizome")
    end
  end

  describe "#setup" do
    before { br.strand.label = "setup" }

    it "runs initializing shell wih public keys" do
      sshable = instance_double(Sshable, host: "hostname", keys: [instance_double(SshKey, public_key: "test key", private_key: "test private key")])
      allow(br).to receive(:sshable).and_return(sshable)
      expect(Util).to receive(:rootish_ssh).with "hostname", "root", ["test private key"], <<FIXTURE
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
end
