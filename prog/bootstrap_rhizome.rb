# frozen_string_literal: true

class Prog::BootstrapRhizome < Prog::Base
  def sshable
    @sshable ||= Sshable[frame["sshable_id"]]
  end

  # A minimal, root-account oriented ssh connection abstraction that
  # relies on the ssh-agent for keys to bootstrap the rhizome user and
  # keys.
  def root_ssh(cmd)
    Net::SSH.start(sshable.host, "root", use_agent: true,
      non_interactive: true, timeout: 30,
      user_known_hosts_file: []) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Could not bootstrap rhizome" unless ret.exitstatus == 0
      ret
    end
  end

  def start
    # YYY: Generate a new SSH key for writing into Sshable, rather
    # than copying authorized_keys in.  It may make sense to use the
    # ssh-agent for preparing new hosts, but not for the Rhizome user
    # once in production.
    root_ssh(<<SH)
apt update && apt -y install ruby-bundler
adduser --disabled-password --gecos '' rhizome
echo 'rhizome ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/98-rhizome
install -D -o rhizome -g rhizome -m 0600 /root/.ssh/authorized_keys /home/rhizome/.ssh/authorized_keys
SH

    pop "rhizome user bootstrapped"
  end
end
