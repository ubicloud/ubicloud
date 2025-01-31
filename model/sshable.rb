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
      super(message_prefix + cmd)
    end

    private

    def message_prefix
      "command exited with an error: "
    end
  end

  class SshTimeout < SshError
    private

    def message_prefix
      "command timed out: "
    end
  end

  def keys
    [raw_private_key_1, raw_private_key_2].compact.map {
      SshKey.from_binary(_1)
    }
  end

  def self.repl?
    REPL
  end

  def repl?
    self.class.repl?
  end

  MAX_TIMEOUT = Strand::LEASE_EXPIRATION - 39

  def cmd(cmd, stdin: nil, log: true, timeout: :default)
    start = Time.now
    stdout = StringIO.new
    stderr = StringIO.new
    exit_code = nil
    exit_signal = nil
    channel_duration = nil

    if timeout == :default
      timeout = if (apoptosis_at = Thread.current[:apoptosis_at])
        (apoptosis_at - start - 2).to_i.clamp(1, MAX_TIMEOUT)
      else
        MAX_TIMEOUT
      end
    end

    if timeout
      # For potential future use, we could wrap command in timeout commana
      # to force exiting after given amount of time:
      # cmd = "sudo timeout #{timeout}s bash -c -- #{cmd.shellescape}"
      wait_deadline = start + timeout + 0.5
    end

    begin
      ch = connect.open_channel do |ch|
        channel_duration = Time.now - start
        ch.exec(cmd) do |ch, success|
          ch.on_data do |ch, data|
            $stderr.write(data) if repl?
            stdout.write(data)
          end

          ch.on_extended_data do |ch, type, data|
            $stderr.write(data) if repl?
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
        end
      end
      channel_wait(ch, wait_deadline)
    rescue
      invalidate_cache_entry
      raise
    end

    stdout_str = stdout.string.freeze
    stderr_str = stderr.string.freeze

    if log
      Clog.emit("ssh cmd execution") do
        finish = Time.now
        embed = {start:, finish:, timeout:, duration: finish - start,
                 cmd:, exit_code:, exit_signal:}

        # Suppress large outputs to avoid annoyance in duplication
        # when in the REPL.  In principle, the user of the REPL could
        # read the Clog output and the feature of printing output in
        # real time to $stderr could be removed, but when supervising
        # a tty, I've found it can be useful to see data arrive in
        # real time from SSH.
        unless repl?
          embed[:stderr] = stderr_str
          embed[:stdout] = stdout_str
        end
        embed[:channel_duration] = channel_duration
        embed[:connect_duration] = @connect_duration if @connect_duration
        {ssh: embed}
      end
    end

    fail (exit_code ? SshError : SshTimeout).new(cmd, stdout_str, stderr_str, exit_code, exit_signal) unless exit_code&.zero?
    stdout_str
  end

  # A huge number of settings are needed to isolate net-ssh from the
  # host system and provide some anti-hanging assurance (keepalive,
  # timeout).
  COMMON_SSH_ARGS = {non_interactive: true, timeout: 10,
                     user_known_hosts_file: [], global_known_hosts_file: [],
                     verify_host_key: :accept_new, keys: [], key_data: [], use_agent: false,
                     keepalive: true, keepalive_interval: 3, keepalive_maxcount: 5}.freeze

  def connect
    Thread.current[:clover_ssh_cache] ||= {}

    # Cache hit.
    if (sess = Thread.current[:clover_ssh_cache][[host, unix_user]])
      return sess
    end

    # Cache miss.
    start = Time.now
    sess = start_fresh_session
    @connect_duration = Time.now - start
    Thread.current[:clover_ssh_cache][[host, unix_user]] = sess
    sess
  end

  def start_fresh_session
    Net::SSH.start(host, unix_user, **COMMON_SSH_ARGS.merge(key_data: keys.map(&:private_key)))
  end

  def invalidate_cache_entry
    Thread.current[:clover_ssh_cache]&.delete([host, unix_user])
  end

  def available?
    cmd("true") && true
  rescue Net::SSH::Disconnect, Net::SSH::ConnectionTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, IOError
    false
  end

  def self.reset_cache
    return [] unless (cache = Thread.current[:clover_ssh_cache])

    cache.filter_map do |key, sess|
      sess.close
      nil
    rescue => e
      e
    ensure
      cache.delete(key)
    end
  end

  private

  def channel_wait(ch, wait_deadline)
    if wait_deadline
      ch.connection.loop do
        ch.active? && Time.now < wait_deadline
      end
      ch.close
    else
      ch.wait
    end
  end
end

# We need to unrestrict primary key so Sshable.new(...).save_changes works
# in sshable_spec.rb.
Sshable.unrestrict_primary_key

# Table: sshable
# Columns:
#  id                | uuid | PRIMARY KEY
#  host              | text |
#  raw_private_key_1 | text |
#  raw_private_key_2 | text |
#  unix_user         | text | NOT NULL DEFAULT 'rhizome'::text
# Indexes:
#  sshable_pkey     | PRIMARY KEY btree (id)
#  sshable_host_key | UNIQUE btree (host)
# Referenced By:
#  vm_host | vm_host_id_fkey | (id) REFERENCES sshable(id)
