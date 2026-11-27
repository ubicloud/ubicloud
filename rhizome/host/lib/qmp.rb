# frozen_string_literal: true

require "json"
require "socket"

class Qmp
  class Error < StandardError; end

  def initialize(socket_path, timeout = 5, response_size_limit = 1048576)
    @socket_path = socket_path
    @timeout = timeout
    @response_size_limit = response_size_limit
  end

  def system_powerdown
    UNIXSocket.open(@socket_path) do |sock|
      @sock = sock
      @buffer = +""
      @deadline = now + @timeout

      greeting = read_message
      raise Error, "unexpected QMP greeting: #{greeting.inspect}" unless greeting.key?("QMP")

      execute("qmp_capabilities")
      execute("system_powerdown")
    end
  end

  private

  def execute(command)
    @sock.write(JSON.generate({execute: command}) + "\n")
    loop do
      message = read_message
      next if message.key?("event")
      raise Error, "QMP command #{command} failed: #{message["error"].inspect}" if message.key?("error")
      return message.fetch("return")
    end
  end

  def read_message
    until (newline = @buffer.index("\n"))
      raise Error, "QMP response size limit exceeded" if @buffer.bytesize > @response_size_limit
      remaining = @deadline - now
      raise Error, "QMP timed out after #{@timeout} seconds" unless remaining > 0 && IO.select([@sock], nil, nil, remaining)
      begin
        @buffer << @sock.readpartial(4096)
      rescue EOFError
        raise Error, "QMP connection closed"
      end
    end
    JSON.parse(@buffer.slice!(0..newline))
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
