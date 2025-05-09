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

  def query_range(query:, start_ts:, end_ts:)
    query_params = [["query", query], ["start", start_ts], ["end", end_ts], ["step", step_seconds(start_ts, end_ts)]]
    query_encoded = URI.encode_www_form(query_params)
    query_results = send_request("GET", "/api/v1/query_range?#{query_encoded}")
    data = JSON.parse(query_results.body)

    return [] unless data["status"] == "success" && data["data"]["resultType"] == "matrix"

    data["data"]["result"].map do |result|
      {
        "labels" => result["metric"] || {},
        "values" => result["values"]
      }
    end

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

  def step_seconds(start_time, end_time)
    num_hours = ((end_time - start_time) / 3600.0).ceil
    # Minimum step is 15 seconds, and we double it for every couple of hours to
    # keep the number of datapoints returned capped at around 480.
    factor = (num_hours / 2.0).ceil
    15 * factor
  end
end

class VictoriaMetrics::ClientError < StandardError; end
