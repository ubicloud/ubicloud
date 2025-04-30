# frozen_string_literal: true

require "excon"
require "json"
require "base64"
require "digest"
require "zlib"

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
end

class VictoriaMetrics::ClientError < StandardError; end
