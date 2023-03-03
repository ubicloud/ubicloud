# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class Sshable < Sequel::Model
  plugin :column_encryption do |enc|
    enc.column :private_key
  end

  class SshError < StandardError; end

  def cmd(cmd)
    ret = connect.exec!(cmd)
    fail SshError.new(ret) unless ret.exitstatus == 0
    ret
  end

  def connect
    Thread.current[:clover_ssh_cache] ||= {}

    # Cache hit.
    if (sess = Thread.current[:clover_ssh_cache][host])
      return sess
    end

    # Cache miss.
    sess = Net::SSH.start(host, "rhizome", non_interactive: true, timeout: 30,
      user_known_hosts_file: [], key_data: [private_key],
      use_agent: Config.development?)
    Thread.current[:clover_ssh_cache][host] = sess
    sess
  end

  def clear_cache
    return [] unless (cache = Thread.current[:clover_ssh_cache])

    cache.values.filter_map do |sess|
      sess.close
      nil
    rescue => e
      e
    end
  end
end
