# frozen_string_literal: true

require "stringio"
require "excon"
require "json"

class LogPoster
  CAPACITY = 16384
  # SEND_THRESHOLD = CAPACITY / 2
  SEND_THRESHOLD = 0

  def initialize(url, headers)
    @url = url
    @headers = headers
    @buf = StringIO.new(String.new(capacity: CAPACITY))
    buf_reinit
  end

  def buf_reinit
    @buf.string.clear
    @buf.rewind
    @buf.write('{ "lines" : [')
    @first = true
  end

  def flush
    @buf.write("]}")
    con = Excon.new(@url, method: :post, body: @buf.string, headers: @headers.merge("Content-Type" => "application/json"))
    resp = con.request
    if resp.status == 200
      puts "Log flush successful"
    else
      puts "Log flush failed, #{resp.status} #{resp.body}"
    end

    buf_reinit
  end

  def buffer_send(o)
    s = case o
    when String
      o
    when Hash
      JSON.generate(o)
    else
      fail "BUG"
        end

    if @buf.size > SEND_THRESHOLD
      flush
    end

    if @first
      @first = false
    else
      @buf.write(",")
    end

    @buf.write(s)
  end
end
