# frozen_string_literal: true

require "excon"
require "json"
require "base64"
require "digest"
require "zlib"

class VictoriaMetrics::Client
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
      Excon.new(endpoint, socket: socket, ssl_cert_store: cert_store)
    else
      Excon.new(endpoint, socket: socket)
    end
  end

  def health
    response = send_request("GET", "/health")
    response.status == 200
  end

  def import_prometheus(scrape, extra_labels = {})
    gzipped_data = gzip(scrape.samples)
    timestamp_msec = (scrape.time.to_f * 1000).to_i

    query_params = [["timestamp", timestamp_msec]]
    extra_labels.each do |key, value|
      query_params.push(["extra_label", "#{key}=#{value}"])
    end
    query_string = URI.encode_www_form(query_params)

    send_request("POST", "/api/v1/import/prometheus?#{query_string}",
      gzipped_data,
      {"Content-Encoding" => "gzip", "Content-Type" => "application/octet-stream"})
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

  Scrape = Data.define(:time, :samples)

  private

  def send_request(method, path, body = nil, headers = {})
    full_path = path

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

  def gzip(string)
    wio = StringIO.new
    gz = Zlib::GzipWriter.new(wio)
    gz.write(string)
    gz.close
    wio.string
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
