# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::BootstrapRhizome do
  subject(:br) {
    described_class.new(Strand.new(prog: "BootstrapRhizome"))
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

    it "runs initializing shell with public keys" do
      sshable = instance_double(Sshable, host: "hostname", keys: [instance_double(SshKey, public_key: "test key", private_key: "test private key")])
      expect(br).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(Util).to receive(:rootish_ssh).with "hostname", "root", ["test private key"], <<'FIXTURE'
set -ueo pipefail
sudo apt-get update
sudo apt-get -y install ruby-bundler
sudo which bundle
sudo userdel -rf rhizome || true
sudo adduser --disabled-password --gecos '' rhizome
echo 'rhizome ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-rhizome
sudo install -d -o rhizome -g rhizome -m 0700 /home/rhizome/.ssh
sudo install -o rhizome -g rhizome -m 0600 /dev/null /home/rhizome/.ssh/authorized_keys
sudo mkdir -p /etc/systemd/logind.conf.d
echo \[Login\]'
'KillOnlyUsers\=rhizome'
'KillUserProcesses\=yes'
' | sudo tee /etc/systemd/logind.conf.d/rhizome.conf > /dev/null
echo \#\ Supported\ HostKey\ algorithms\ by\ order\ of\ preference.'
'HostKey\ /etc/ssh/ssh_host_ed25519_key'
'HostKey\ /etc/ssh/ssh_host_rsa_key'
'HostKey\ /etc/ssh/ssh_host_ecdsa_key'
''
'KexAlgorithms\ curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256'
''
'Ciphers\ chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr'
''
'MACs\ hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com'
''
'\#\ Password\ based\ logins\ are\ disabled\ -\ only\ public\ key\ based\ logins\ are\ allowed.'
'AuthenticationMethods\ publickey'
''
'\#\ LogLevel\ VERBOSE\ logs\ user\'s\ key\ fingerprint\ on\ login.\ Needed\ to\ have\ a\ clear\ audit\ track\ of\ which\ key\ was\ using\ to\ log\ in.'
'LogLevel\ VERBOSE'
''
'\#\ Terminate\ sessions\ with\ clients\ that\ cannot\ return\ packets\ rapidly.'
'ClientAliveInterval\ 2'
'ClientAliveCountMax\ 4'
' | sudo tee /etc/ssh/sshd_config.d/10-clover.conf > /dev/null
echo test\ key | sudo tee /home/rhizome/.ssh/authorized_keys > /dev/null
sync
FIXTURE

      expect { br.setup }.to hop("start", "InstallRhizome")
    end

    it "exits once InstallRhizome has returned" do
      br.strand.retval = {"msg" => "installed rhizome"}
      expect { br.setup }.to exit({"msg" => "rhizome user bootstrapped and source installed"})
    end
  end
end
