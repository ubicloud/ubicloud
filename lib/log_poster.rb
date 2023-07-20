# frozen_string_literal: true

require "stringio"
require "excon"

class LogPoster
  CAPACITY = 16384
  SEND_THRESHOLD = CAPACITY / 2

  def initialize(url, headers)
    @url = url
    @headers = headers
    @buf = StringIO.new(String.new(capacity: CAPACITY))
    buf_init
  end

  def buf_reinit
    @buf.string.clear
    @buf.rewind
    @buf.write("[")
    @first = true
  end

  def flush
    @buf.write("]")
    con = Excon.new(@url, method: :post, body: @buf.string, headers: @headers.merge("Content-Type" => "application/json"))
    resp = con.request
    if resp.status == 200
      puts "Log flush successful"
    else
      puts "Log flush failed, #{resp.status} #{resp.body}"
    end

    buf_reinit
  end

  def buffer(s)
    if @first
      @first = false
    else
      @buf.write(",")
    end

    @buf.write(s)

    if @buf.size > SEND_THRESHOLD
      flush
    end
  end
end

Unreloader.reload!
LogPoster.new("https://api.axiom.co/v1/datasets/clover-fdr/ingest", "Authorization" => "Bearer xaat-2be73111-f0bf-402e-96a5-148ee58bbb50")
