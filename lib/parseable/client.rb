# frozen_string_literal: true

require "excon"
require "json"
require "base64"
require "zlib"

class Parseable::Client
  class Error < StandardError
    attr_reader :response_body, :status

    def initialize(message, response_body: nil, status: nil)
      super(message)
      @response_body = response_body
      @status = status
    end
  end

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

  def create_stream(stream_name:)
    send_request("PUT", "/api/v1/logstream/#{stream_name}")
  rescue Parseable::Client::Error => ex
    raise unless ex.response_body.to_s.include?("already exists")
  end

  def delete_stream(stream_name:)
    send_request("DELETE", "/api/v1/logstream/#{stream_name}", accepted_statuses: [200, 404])
  end

  def create_role(role_name:, privileges:)
    body = JSON.generate(privileges)
    send_request("PUT", "/api/v1/role/#{role_name}", body, {"Content-Type" => "application/json"})
  end

  def delete_role(role_name:)
    send_request("DELETE", "/api/v1/role/#{role_name}", accepted_statuses: [200, 404])
  end

  def create_user(user_id:, roles: [])
    retries = 0

    begin
      body = JSON.generate(roles)
      response = send_request("POST", "/api/v1/user/#{user_id}", body, {"Content-Type" => "application/json"})
      response.body
    rescue Parseable::Client::Error => ex
      if ex.response_body.to_s.include?("already exists")
        retries += 1
        delete_user(user_id:)
        retry unless retries > 3
      end
      raise
    end
  end

  def delete_user(user_id:)
    send_request("DELETE", "/api/v1/user/#{user_id}", accepted_statuses: [200, 404])
  end

  def query(sql, start_time:, end_time:)
    body = JSON.generate({query: sql, startTime: start_time, endTime: end_time})
    response = send_request("POST", "/api/v1/query", body,
      {"Content-Type" => "application/json"})
    JSON.parse(response.body)
  end

  private

  def send_request(method, path, body = nil, headers = {}, accepted_statuses: [200])
    if @username && @password
      auth = Base64.strict_encode64("#{@username}:#{@password}")
      headers["Authorization"] = "Basic #{auth}"
    end

    response = @client.request(method:, path:, body:, headers:)
    if accepted_statuses.include?(response.status)
      response
    else
      raise Parseable::Client::Error.new(
        "Parseable Client error, method: #{method}, path: #{path}, status code: #{response.status}",
        response_body: response.body,
        status: response.status,
      )
    end
  end
end
