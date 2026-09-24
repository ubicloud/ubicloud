# frozen_string_literal: true

# Minimal SigV4 S3 client: enough to create a bucket and list what ubiblk's
# archive wrote. Stdlib only, so it runs on a host with no gems installed.

require "net/http"
require "openssl"
require "time"
require "uri"

class MiniS3
  def initialize(endpoint:, access_key:, secret_key:, region: "us-east-1")
    @uri = URI(endpoint)
    @access_key = access_key
    @secret_key = secret_key
    @region = region
  end

  def create_bucket(bucket)
    code, body = request("PUT", "/#{bucket}")
    return true if (200..299).cover?(code)
    return true if body.to_s.include?("BucketAlreadyOwnedByYou") || body.to_s.include?("BucketAlreadyExists")
    raise "create_bucket #{bucket} failed: #{code} #{body}"
  end

  # Returns [[key, size], ...]
  def list(bucket, prefix = "")
    code, body = request("GET", "/#{bucket}", "list-type=2&prefix=#{URI.encode_www_form_component(prefix)}")
    raise "list #{bucket} failed: #{code} #{body}" unless (200..299).cover?(code)
    body.scan(%r{<Key>(.*?)</Key>.*?<Size>(\d+)</Size>}m).map { |k, s| [k, s.to_i] }
  end

  def total_size(bucket, prefix = "")
    list(bucket, prefix).sum { _2 }
  end

  def request(method, path, query = "")
    now = Time.now.utc
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")
    payload_hash = OpenSSL::Digest::SHA256.hexdigest("")
    host = "#{@uri.host}:#{@uri.port}"

    canonical = [method, path, query,
      "host:#{host}\n" \
      "x-amz-content-sha256:#{payload_hash}\n" \
      "x-amz-date:#{amz_date}\n",
      "host;x-amz-content-sha256;x-amz-date", payload_hash].join("\n")
    scope = "#{date}/#{@region}/s3/aws4_request"
    to_sign = ["AWS4-HMAC-SHA256", amz_date, scope,
      OpenSSL::Digest::SHA256.hexdigest(canonical)].join("\n")

    key = "AWS4#{@secret_key}"
    [date, @region, "s3", "aws4_request"].each { key = OpenSSL::HMAC.digest("SHA256", key, _1) }
    signature = OpenSSL::HMAC.hexdigest("SHA256", key, to_sign)

    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = @uri.scheme == "https"
    req = Net::HTTP.const_get(method.capitalize).new(query.empty? ? path : "#{path}?#{query}")
    req["Host"] = host
    req["x-amz-date"] = amz_date
    req["x-amz-content-sha256"] = payload_hash
    req["Authorization"] = "AWS4-HMAC-SHA256 Credential=#{@access_key}/#{scope}," \
      "SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=#{signature}"
    res = http.request(req)
    [res.code.to_i, res.body]
  end
end
