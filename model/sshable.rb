# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class Sshable < Sequel::Model
  plugin :column_encryption do |enc|
    enc.column :private_key
  end

  class SshError < StandardError; end

  def cmd(cmd)
    ret = begin
      connect.exec!(cmd)
    rescue
      invalidate_cache_entry
      raise
    end
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
      user_known_hosts_file: [], key_data: [private_key].compact,
      use_agent: Config.development?)
    Thread.current[:clover_ssh_cache][host] = sess
    sess
  end

  def invalidate_cache_entry
    Thread.current[:clover_ssh_cache]&.delete(host)
  end

  def self.reset_cache
    return [] unless (cache = Thread.current[:clover_ssh_cache])

    cache.filter_map do |host, sess|
      sess.close
      nil
    rescue => e
      e
    ensure
      cache.delete(host)
    end
  end
end
