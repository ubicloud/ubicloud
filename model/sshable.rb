# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class Sshable < Sequel::Model
  plugin :column_encryption do |enc|
    enc.column :raw_private_key_1
    enc.column :raw_private_key_2
  end

  class SshError < StandardError; end

  def keys
    [raw_private_key_1, raw_private_key_2].compact.map {
      SshKey.from_binary(_1)
    }
  end

  def cmd(cmd)
    ret = begin
      connect.exec!(cmd)
    rescue
      invalidate_cache_entry
      raise
    end
    fail SshError.new(ret) unless ret.exitstatus.zero?
    ret
  end

  # A huge number of settings are needed to isolate net-ssh from the
  # host system and provide some anti-hanging assurance (keepalive,
  # timeout).  Set them up here, and expect callers to override when
  # necessary.
  COMMON_SSH_ARGS = {non_interactive: true, timeout: 30,
                     user_known_hosts_file: [], global_known_hosts_file: [],
                     keys: [], key_data: [], use_agent: false,
                     keepalive: true, keepalive_interval: 3, keepalive_maxcount: 5}.freeze

  def connect
    Thread.current[:clover_ssh_cache] ||= {}

    # Cache hit.
    if (sess = Thread.current[:clover_ssh_cache][host])
      return sess
    end

    # Cache miss.
    sess = Net::SSH.start(host, "rhizome", **COMMON_SSH_ARGS.merge(key_data: keys.map(&:private_key)))
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
