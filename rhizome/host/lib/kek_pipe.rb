# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "timeout"

module KekPipe
  WRITE_TIMEOUT_SEC = 5

  def with_kek_pipe(kek_pipe, owner: nil)
    rm_if_exists(kek_pipe)
    File.mkfifo(kek_pipe, 0o600)
    FileUtils.chown owner, owner, kek_pipe if owner
    yield kek_pipe
  ensure
    rm_if_exists(kek_pipe)
  end

  def write_kek_to_pipe(kek_pipe, payload, timeout_sec: WRITE_TIMEOUT_SEC)
    Timeout.timeout(timeout_sec) do
      File.write(kek_pipe, payload, mode: File::WRONLY)
    end
  end

  def run_with_kek_pipe(command, kek_pipe:, kek_content:, stdin: nil, env: {}, owner: nil, kek_write_timeout_sec: WRITE_TIMEOUT_SEC)
    with_kek_pipe(kek_pipe, owner: owner) do |pipe|
      stdin_r, stdin_w = IO.pipe if stdin
      spawn_opts = stdin_r ? {in: stdin_r} : {}

      begin
        pid = Process.spawn(env, *command, **spawn_opts)
        stdin_r&.close

        if stdin
          stdin_writer = Thread.new do
            stdin_w.write(stdin)
          rescue Errno::EPIPE
            # Child exited before consuming all stdin
          rescue IOError => e
            # Another possible error if child exited before consuming all stdin
            raise unless e.message.include?("stream closed")
          ensure
            stdin_w.close
          end
        end

        write_kek_to_pipe(pipe, kek_content, timeout_sec: kek_write_timeout_sec)

        _, status = Process.wait2(pid)
      rescue => e
        if pid
          begin
            Process.kill("TERM", pid)
          rescue Errno::ESRCH
            # Child has already exited.
          end
          Process.waitpid(pid)
        end
        raise "error writing KEK to pipe: #{e.message}"
      ensure
        stdin_r&.close
        stdin_w&.close
        stdin_writer&.join
      end

      raise CommandFail.new("command failed: #{command.join(" ")}", "", "") unless status.success?
    end
  end
end
