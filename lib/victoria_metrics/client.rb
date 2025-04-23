# frozen_string_literal: true

require "excon"
require "json"
require "base64"
require "digest"

class VictoriaMetrics::Client
  def initialize(endpoint:, ssl_ca_file_data: nil, socket: nil, username: nil, password: nil)
    @endpoint = endpoint
    @username = username
    @password = password
    @client = if ssl_ca_file_data
      ca_bundle_filename = File.join(Dir.pwd, "var", "ca_bundles", Digest::SHA256.hexdigest(ssl_ca_file_data) + ".crt")
      Util.safe_write_to_file(ca_bundle_filename, ssl_ca_file_data) unless File.exist?(ca_bundle_filename)
      Excon.new(endpoint, socket: socket, ssl_ca_file: ca_bundle_filename)
    else
      Excon.new(endpoint, socket: socket)
    end
  end

  def health
    response = send_request("GET", "/health")
    response.status == 200
  end

  private

  def send_request(method, path, body = nil)
    full_path = path
    headers = {}

    if @username && @password
      auth = Base64.strict_encode64("#{@username}:#{@password}")
      headers["Authorization"] = "Basic #{auth}"
    end

    response = @client.request(method: method, path: full_path, body: body, headers: headers)
    if [200, 204, 206, 404].include?(response.status)
      response
    else
      raise VictoriaMetrics::ClientError, "VictoriaMetrics Client error, method: #{method}, path: #{path}, status code: #{response.status}"
    end
  end
end

class VictoriaMetrics::ClientError < StandardError; end
