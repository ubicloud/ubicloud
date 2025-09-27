# frozen_string_literal: true

require "digest"
require "openssl"

# This is a ruby implementation of the AWS Signature Version 4 signing process.
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/RESTAuthentication.html
# This algorithm uses secret_key, date and the region to create a signing key.
# This signing key is then used to sign the request header payload that contains
# the request method, uri, headers, date and region. The signature is then
# added to the Authorization header of the request.
# As a result, we get an authorization header that is valid only until server
# time is within the acceptable time range. According to the MinIO source code,
# the acceptable time range is 15 minutes.
# https://github.com/minio/minio/blob/7926df0b80f557d0160153c5156b9b6d6b12b42e/cmd/globals.go#L93
class Minio::HeaderSigner
  SERVICE_NAME = "s3"
  def build_headers(method, uri, body, creds, region, needs_md5 = false)
    date = Time.now.utc
    @headers = {}
    @headers["Host"] = uri.host + ":" + uri.port.to_s
    @headers["User-Agent"] = "MinIO Ubicloud"
    @headers["Content-Type"] = "application/octet-stream"
    @headers["x-amz-content-sha256"] = sha256_hash(body)
    @headers["x-amz-date"] = time_to_amz_date(date)
    @headers["Content-Length"] = body.length.to_s if body
    @headers["Content-Md5"] = md5sum_hash(body) if body && needs_md5
    sign_v4_s3(method, uri, region, creds, date)
  end

  def sign_v4_s3(method, uri, region, credentials, date)
    scope = get_scope(date, region)
    canonical_request_hash, signed_headers = get_canonical_request_hash(method, uri, @headers)
    string_to_sign = get_string_to_sign(date, scope, canonical_request_hash)
    signing_key = get_signing_key(credentials[:secret_key], date, region)
    signature = hmac_hash(signing_key, string_to_sign.encode("UTF-8"), true)
    authorization = get_authorization(credentials[:access_key], scope, signed_headers, signature)
    @headers["Authorization"] = authorization

    @headers
  end

  def presign_v4(method, uri, region, credentials, date, expires)
    scope = get_scope(date, region)
    canonical_request_hash, uri = get_presign_canonical_request_hash(method, uri, credentials[:access_key], scope, date, expires)
    string_to_sign = get_string_to_sign(date, scope, canonical_request_hash)
    signing_key = get_signing_key(credentials[:secret_key], date, region)
    signature = hmac_hash(signing_key, string_to_sign.encode("UTF-8"), true)

    uri.query = uri.query + "&#{URI.encode_www_form({"X-Amz-Signature" => signature})}"
    uri
  end

  private

  def get_authorization(access_key, scope, signed_headers, signature)
    "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  def get_signing_key(secret_key, date, region)
    date_key = hmac_hash("AWS4#{secret_key}", time_to_signer_date(date))
    date_region_key = hmac_hash(date_key, region)
    date_region_service_key = hmac_hash(date_region_key, SERVICE_NAME)
    hmac_hash(date_region_service_key, "aws4_request")
  end

  def get_string_to_sign(date, scope, canonical_request_hash)
    "AWS4-HMAC-SHA256\n#{time_to_amz_date(date)}\n#{scope}\n#{canonical_request_hash}"
  end

  def get_canonical_request_hash(method, uri, headers)
    canonical_headers, signed_headers = get_canonical_headers(headers)
    canonical_query_string = get_canonical_query_string(uri.query)

    canonical_request = [
      method,
      uri.path,
      canonical_query_string,
      canonical_headers,
      "",
      signed_headers,
      headers["x-amz-content-sha256"]
    ].join("\n")

    [sha256_hash(canonical_request), signed_headers]
  end

  def get_presign_canonical_request_hash(method, uri, access_key, scope, date, expires)
    canonical_headers, signed_headers = "host:" + "#{uri.host}:#{uri.port}", "host"

    uri.query = URI.encode_www_form({
      "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
      "X-Amz-Credential" => access_key + "/" + scope,
      "X-Amz-Date" => time_to_amz_date(date),
      "X-Amz-Expires" => expires,
      "X-Amz-SignedHeaders" => signed_headers
    })
    canonical_query_string = get_canonical_query_string(uri.query)

    canonical_request = [
      method,
      uri.path,
      canonical_query_string,
      canonical_headers,
      "",
      signed_headers,
      "UNSIGNED-PAYLOAD"
    ].join("\n")

    [sha256_hash(canonical_request), uri]
  end

  def get_canonical_query_string(query)
    query ||= ""
    pairs = query.split("&").map { |param| param.split("=") }
    pairs.sort.map { |key, value| "#{key}=#{value}" }.join("&")
  end

  def get_canonical_headers(headers)
    canonical_headers = {}
    headers.each do |key, value|
      key = key.downcase
      next if (key == "authorization") || (key == "user-agent")

      value = value.gsub(/\s+/, " ")
      canonical_headers[key] = value
    end
    canonical_headers = canonical_headers.sort.to_h
    signed_headers = canonical_headers.keys.join(";")
    headers_string = canonical_headers.map { |k, v| "#{k}:#{v}" }.join("\n")
    [headers_string, signed_headers]
  end

  def get_scope(date, region)
    "#{time_to_signer_date(date)}/#{region}/#{SERVICE_NAME}/aws4_request"
  end

  def sha256_hash(data)
    # Ensure data is not nil, default to an empty string if it is
    data ||= ""
    # Compute SHA-256 hash
    Digest::SHA256.hexdigest(data)
  end

  def hmac_hash(key, data, hexdigest = false)
    digest = OpenSSL::Digest.new("sha256")
    hmac = OpenSSL::HMAC.digest(digest, key, data)
    hexdigest ? hmac.unpack1("H*") : hmac
  end

  def time_to_amz_date(date)
    date.strftime("%Y%m%dT%H%M%SZ")
  end

  def time_to_signer_date(date)
    date.strftime("%Y%m%d")
  end

  def md5sum_hash(data)
    Base64.strict_encode64(Digest::MD5.digest(data))
  end
end
