# frozen_string_literal: true

require "net/ssh"

class Prog::BootstrapRhizome < Prog::Base
  subject_is :sshable

  def user
    @user ||= frame.fetch("user", "root")
  end

  # A minimal, non-cached SSH implementation that is good enough to be
  # make a given Sshable work with the `rhizome` user.
  #
  # It must log into an account that can escalate to root via "sudo,"
  # which typically includes the "root" account reflexively.  The
  # ssh-agent is employed by default here, since personnel are thought
  # to be involved with preparing new VmHosts.
  def rootish_ssh(cmd)
    Net::SSH.start(sshable.host, user,
      Sshable::COMMON_SSH_ARGS.merge(key_data: sshable.keys.map(&:private_key),
        use_agent: Config.development?)) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Could not bootstrap rhizome" unless ret.exitstatus.zero?
      ret
    end
  end

  label def start
    sshable.update(raw_private_key_1: SshKey.generate.keypair)
    hop_setup
  end

  label def setup
    pop "rhizome user bootstrapped and source installed" if retval&.dig("msg") == "installed rhizome"

    rootish_ssh(<<SH)
set -ueo pipefail
sudo apt update && sudo apt-get -y install ruby-bundler
sudo adduser --disabled-password --gecos '' rhizome
echo 'rhizome ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-rhizome
sudo install -d -o rhizome -g rhizome -m 0700 /home/rhizome/.ssh
sudo install -o rhizome -g rhizome -m 0600 /dev/null /home/rhizome/.ssh/authorized_keys
echo #{sshable.keys.map(&:public_key).join("\n")} | sudo tee /home/rhizome/.ssh/authorized_keys > /dev/null
SH

    push Prog::InstallRhizome
  end
end
