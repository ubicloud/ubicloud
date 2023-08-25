# frozen_string_literal: true

require "net/ssh"

module Util
  # A minimal, non-cached SSH implementation.
  #
  # It must log into an account that can escalate to root via "sudo,"
  # which typically includes the "root" account reflexively.  The
  # ssh-agent is employed by default here, since personnel are thought
  # to be involved with preparing new VmHosts.
  def self.rootish_ssh(host, user, keys, cmd)
    Net::SSH.start(host, user,
      Sshable::COMMON_SSH_ARGS.merge(key_data: keys,
        use_agent: Config.development?)) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Ssh command failed: #{ret}" unless ret.exitstatus.zero?
      ret
    end
  end
end
