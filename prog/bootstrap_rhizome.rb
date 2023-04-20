# frozen_string_literal: true

class Prog::BootstrapRhizome < Prog::Base
  def user
    @user ||= frame.fetch("user", "root")
  end

  # A minimal, non-cached SSH implementation that is good enough to be
  # make a given Sshable work with the `rhizome` user.
  #
  # It must log into an account that can escalate to root via "sudo,"
  # which typically includes the "root" account reflexively.
  def rootish_ssh(cmd)
    Net::SSH.start(sshable.host, user, use_agent: true,
      non_interactive: true, timeout: 30,
      keepalive: true, keepalive_interval: 3, keepalive_maxcount: 5,
      user_known_hosts_file: []) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Could not bootstrap rhizome" unless ret.exitstatus.zero?
      ret
    end
  end

  def start
    pop "rhizome user bootstrapped and source installed" if retval == "installed rhizome"

    # YYY: Generate a new SSH key for writing into Sshable, rather
    # than copying authorized_keys in.  It may make sense to use the
    # ssh-agent for preparing new hosts, but not for the Rhizome user
    # once in production.
    home = (user == "root") ? "/root" : "/home/#{user}"
    authorized_keys_file = File.join(home, ".ssh", "authorized_keys")

    rootish_ssh(<<SH)
set -ueo pipefail
sudo apt update && sudo apt-get -y install ruby-bundler
sudo adduser --disabled-password --gecos '' rhizome
echo 'rhizome ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-rhizome
sudo install -D -o rhizome -g rhizome -m 0600 #{authorized_keys_file.shellescape} /home/rhizome/.ssh/authorized_keys
SH

    push Prog::InstallRhizome, {sshable_id: sshable_id}
  end
end
