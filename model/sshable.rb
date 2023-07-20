# frozen_string_literal: true

require "net/ssh"
require_relative "../model"

class Sshable < Sequel::Model
  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :raw_private_key_1
    enc.column :raw_private_key_2
  end

  class SshError < StandardError
    attr_reader :stdout, :stderr, :exit_code, :exit_signal

    def initialize(cmd, stdout, stderr, exit_code, exit_signal)
      @exit_code = exit_code
      @exit_signal = exit_signal
      @stdout = stdout
      @stderr = stderr
      super "command exited with an error: " + cmd
    end
  end

  def self.ubid_type
    UBID::TYPE_SSHABLE
  end

  def keys
    [raw_private_key_1, raw_private_key_2].compact.map {
      SshKey.from_binary(_1)
    }
  end

  def cmd(cmd, stdin: nil)
    stdout = StringIO.new
    stderr = StringIO.new
    exit_code = nil
    exit_signal = nil

    begin
      connect.open_channel do |ch|
        ch.exec(cmd) do |ch, success|
          ch.on_data do |ch, data|
            $stderr.write(data) if REPL
            stdout.write(data)
          end

          ch.on_extended_data do |ch, type, data|
            $stderr.write(data) if REPL
            stderr.write(data)
          end

          ch.on_request("exit-status") do |ch2, data|
            exit_code = data.read_long
          end

          ch.on_request("exit-signal") do |ch2, data|
            exit_signal = data.read_long
          end
          ch.send_data stdin
          ch.eof!
          ch.wait
        end
      end.wait
    rescue
      invalidate_cache_entry
      raise
    end

    ret = stdout.string.freeze
    fail SshError.new(cmd, ret, stderr.string.freeze, exit_code, exit_signal) unless exit_code.zero?
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

# We need to unrestrict primary key so Sshable.new(...).save_changes works
# in sshable_spec.rb.
Sshable.unrestrict_primary_key
