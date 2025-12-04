# frozen_string_literal: true

require_relative "../model"
require_relative "../lib/net_ssh"

class Sshable < Sequel::Model
  prepend NetSsh::WarnUnsafe::Sshable

  # We need to unrestrict primary key so Sshable.new(...).save_changes works
  # in sshable_spec.rb.
  unrestrict_primary_key

  plugin ResourceMethods, encrypted_columns: [:raw_private_key_1, :raw_private_key_2]

  SSH_CONNECTION_ERRORS = [
    Net::SSH::Disconnect,
    Net::SSH::ConnectionTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    IOError
  ].freeze

  def admin_label
    "#{unix_user}@#{host}"
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
      SshKey.from_binary(it)
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

    wait_deadline = if timeout
      start + timeout + 0.5
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
        embed = {ubid:, start:, finish:, timeout:, duration: finish - start,
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

  def d_check(unit_name)
    cmd("common/bin/daemonizer2 check :unit_name", unit_name:)
  end

  def d_clean(unit_name)
    cmd("common/bin/daemonizer2 clean :unit_name", unit_name:)
  end

  def d_run(unit_name, *shelljoin_run_command, stdin: nil, log: true)
    cmd("common/bin/daemonizer2 run :unit_name :shelljoin_run_command", unit_name:, shelljoin_run_command:, stdin:, log:)
  end

  def d_restart(unit_name)
    cmd("common/bin/daemonizer2 restart :unit_name", unit_name:)
  end

  # A huge number of settings are needed to isolate net-ssh from the
  # host system and provide some anti-hanging assurance (keepalive,
  # timeout).
  COMMON_SSH_ARGS = {non_interactive: true, timeout: 10,
                     user_known_hosts_file: [], global_known_hosts_file: [],
                     verify_host_key: :accept_new, keys: [], key_data: [], use_agent: false,
                     keepalive: true, keepalive_interval: 3, keepalive_maxcount: 5}.freeze

  def maybe_ssh_session_lock_name
    SSH_SESSION_LOCK_NAME if defined?(SSH_SESSION_LOCK_NAME)
  end

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

    if (lock_name = maybe_ssh_session_lock_name)
      lock_contents = <<LOCK
exec 999>/dev/shm/session-lock-:lock_name || exit 92
flock -xn 999 || { echo "Another session active: " :lock_name; exit 124; }
exec -a session-lock-:lock_name sleep infinity </dev/null >/dev/null 2>&1 &
disown
LOCK

      begin
        cmd(lock_contents, lock_name:, log: false)
      rescue SshError => ex
        session_fail_msg = case (exit_code = ex.exit_code)
        when 92
          "could not create session lock file for #{lock_name}"
        when 124
          "session lock conflict for #{lock_name}"
        else
          "unknown SshError"
        end

        Clog.emit("session lock failure") do
          {contended_session_lock: {exit_code:, session_fail_msg:, sshable_ubid: ubid.to_s, prog: Prog::Base.current_prog}}
        end
      end
    end

    sess
  end

  def start_fresh_session(&block)
    Net::SSH.start(host, unix_user, **COMMON_SSH_ARGS, key_data: keys.map(&:private_key), &block)
  end

  def invalidate_cache_entry
    Thread.current[:clover_ssh_cache]&.delete([host, unix_user])
  end

  def available?
    cmd("true") && true
  rescue *SSH_CONNECTION_ERRORS
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
