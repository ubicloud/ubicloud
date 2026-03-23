# frozen_string_literal: true

require "excon"
require "json"
require "base64"

class Parseable::Client
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

  def health
    response = send_request("GET", "/api/v1/liveness")
    response.status == 200
  end

  def create_stream(stream_name)
    send_request("PUT", "/api/v1/logstream/#{stream_name}")
  end

  def ingest(stream_name, events)
    body = JSON.generate(Array(events))
    send_request("POST", "/api/v1/logstream/#{stream_name}", body,
      {"Content-Type" => "application/json"})
  end

  def query(sql)
    body = JSON.generate({query: sql})
    response = send_request("POST", "/api/v1/query", body,
      {"Content-Type" => "application/json"})
    JSON.parse(response.body)
  end

  private

  def send_request(method, path, body = nil, headers = {})
    if @username && @password
      auth = Base64.strict_encode64("#{@username}:#{@password}")
      headers["Authorization"] = "Basic #{auth}"
    end

    response = @client.request(method:, path:, body:, headers:)
    if [200, 201, 204].include?(response.status)
      response
    else
      raise Parseable::ClientError, "Parseable Client error, method: #{method}, path: #{path}, status code: #{response.status}"
    end
  end
end

class Parseable::ClientError < StandardError; end
