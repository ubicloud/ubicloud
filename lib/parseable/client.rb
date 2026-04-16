# frozen_string_literal: true

require "excon"
require "json"
require "base64"
require "zlib"

class Parseable::Client
  class Error < StandardError; end

  def initialize(endpoint:, ssl_ca_data: nil, socket: nil, username: nil, password: nil)
    @endpoint = endpoint
    @username = username
    @password = password
    @client = if ssl_ca_data
      cert_store = OpenSSL::X509::Store.new
      certs_pem = ssl_ca_data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
      certs_pem.each do |cert_pem|
        cert = OpenSSL::X509::Certificate.new(cert_pem)
        cert_store.add_cert(cert)
      end
      Excon.new(endpoint, socket:, ssl_cert_store: cert_store)
    else
      Excon.new(endpoint, socket:)
    end
  end

  def healthy?
    response = send_request("GET", "/api/v1/liveness")
    response.status == 200
  end

  def create_stream(stream_name)
    send_request("PUT", "/api/v1/logstream/#{stream_name}")
  end

  def emit(stream_name, events)
    body = gzip(JSON.generate(events.is_a?(Array) ? events : [events]))
    send_request("POST", "/api/v1/logstream/#{stream_name}", body,
      {"Content-Type" => "application/json", "Content-Encoding" => "gzip"})
  end

  def query(sql, start_time:, end_time:)
    body = JSON.generate({query: sql, startTime: start_time, endTime: end_time})
    response = send_request("POST", "/api/v1/query", body,
      {"Content-Type" => "application/json"})
    JSON.parse(response.body)
  end

  private

  def gzip(string)
    wio = StringIO.new
    gz = Zlib::GzipWriter.new(wio)
    gz.write(string)
    gz.close
    wio.string
  end

  def send_request(method, path, body = nil, headers = {})
    if @username && @password
      auth = Base64.strict_encode64("#{@username}:#{@password}")
      headers["Authorization"] = "Basic #{auth}"
    end

    response = @client.request(method:, path:, body:, headers:)
    if response.status == 200
      response
    else
      raise Parseable::Client::Error, "Parseable Client error, method: #{method}, path: #{path}, status code: #{response.status}"
    end
  end
end
