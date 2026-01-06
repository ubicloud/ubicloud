# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::BootstrapRhizome do
  subject(:br) { described_class.new(st) }

  let(:ssh_key) { SshKey.new(Ed25519::SigningKey.new("\x00" * 32)) }
  let(:sshable) {
    Sshable.create(
      host: "192.168.1.100",
      raw_private_key_1: ssh_key.keypair
    )
  }
  let(:st) {
    Strand.create_with_id(sshable, prog: "BootstrapRhizome", stack: [{"target_folder" => "host"}], label: "start")
  }

  describe "#start" do
    it "generates a keypair" do
      sshable.update(raw_private_key_1: nil)
      expect { br.start }.to hop("setup", "BootstrapRhizome")
      expect(sshable.reload.raw_private_key_1).to be_instance_of(String)
      expect(sshable.raw_private_key_1.length).to eq(64)
    end

    it "does not generate a keypair if there is already one" do
      original_key = sshable.raw_private_key_1
      expect { br.start }.to hop("setup", "BootstrapRhizome")
      expect(sshable.reload.raw_private_key_1).to eq(original_key)
    end
  end

  describe "#setup" do
    before { st.update(label: "setup") }

    it "runs initializing shell with public keys" do
      session = Net::SSH::Connection::Session.allocate
      expect(Net::SSH).to receive(:start).and_yield(session)
      expect(session).to receive(:_exec!).with(<<'FIXTURE').and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("", 0))
set -ueo pipefail
if [ false = false ]; then
  sudo apt-get update
  sudo apt-get -y install ruby-bundler
fi
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
''
'\#\ Increase\ the\ maximum\ number\ of\ concurrent\ unauthenticated\ connections.'
'MaxStartups\ 50:1:150'
''
'\#\ Reduce\ the\ time\ allowed\ for\ login.'
'LoginGraceTime\ 20s'
' | sudo tee /etc/ssh/sshd_config.d/10-clover.conf > /dev/null
echo ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAIDtqJ7zOtqQtYqOo0CpvDXNlMhV3HeJDpjrASKGLWdop | sudo tee /home/rhizome/.ssh/authorized_keys > /dev/null
sync
FIXTURE

      expect { br.setup }.to hop("start", "InstallRhizome")
    end

    it "exits once InstallRhizome has returned" do
      st.update(retval: {"msg" => "installed rhizome"})
      expect { br.setup }.to exit({"msg" => "rhizome user bootstrapped and source installed"})
    end
  end
end
