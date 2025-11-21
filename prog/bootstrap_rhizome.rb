# frozen_string_literal: true

require_relative "../lib/util"

class Prog::BootstrapRhizome < Prog::Base
  subject_is :sshable
  semaphore :destroy

  def user
    @user ||= frame.fetch("user", "root")
  end

  def before_run
    when_destroy_set? do
      pop "exiting early due to destroy semaphore"
    end
  end

  label def start
    sshable.update(raw_private_key_1: SshKey.generate.keypair) if sshable.raw_private_key_1.nil?
    hop_setup
  end

  # Taken from https://infosec.mozilla.org/guidelines/openssh
  SSHD_CONFIG = <<SSHD_CONFIG
# Supported HostKey algorithms by order of preference.
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key

KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com

# Password based logins are disabled - only public key based logins are allowed.
AuthenticationMethods publickey

# LogLevel VERBOSE logs user's key fingerprint on login. Needed to have a clear audit track of which key was using to log in.
LogLevel VERBOSE

# Terminate sessions with clients that cannot return packets rapidly.
ClientAliveInterval 2
ClientAliveCountMax 4

# Increase the maximum number of concurrent unauthenticated connections.
MaxStartups 50:1:150

# Reduce the time allowed for login.
LoginGraceTime 20s
SSHD_CONFIG

  LOGIND_CONFIG = <<LOGIND
[Login]
KillOnlyUsers=rhizome
KillUserProcesses=yes
LOGIND

  label def setup
    pop "rhizome user bootstrapped and source installed" if retval&.dig("msg") == "installed rhizome"

    key_data = sshable.keys.map(&:private_key)
    Util.rootish_ssh(sshable.host, user, key_data, <<SH)
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
echo #{LOGIND_CONFIG.shellescape} | sudo tee /etc/systemd/logind.conf.d/rhizome.conf > /dev/null
echo #{SSHD_CONFIG.shellescape} | sudo tee /etc/ssh/sshd_config.d/10-clover.conf > /dev/null
echo #{sshable.keys.map(&:public_key).join("\n").shellescape} | sudo tee /home/rhizome/.ssh/authorized_keys > /dev/null
sync
SH

    push Prog::InstallRhizome, {"target_folder" => frame["target_folder"]}
  end
end
