# frozen_string_literal: true

require "excon"
require "json"
require "nokogiri"
require "cgi"

REGION = "us-east-1"
ADMIN_URI_PATH = "/minio/admin/v3"

class Minio::Client
  def initialize(endpoint:, access_key:, secret_key:, ssl_ca_data:, socket: nil)
    cert_store = OpenSSL::X509::Store.new
    certs_pem = ssl_ca_data.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
    certs_pem.each do |cert_pem|
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      cert_store.add_cert(cert)
    end
    @creds = {access_key: access_key, secret_key: secret_key}
    @endpoint = endpoint
    @client = Excon.new(endpoint, socket: socket, ssl_cert_store: cert_store)
    @signer = Minio::HeaderSigner.new
    @crypto = Minio::Crypto.new
  end

  private def admin_uri(path)
    URI.parse("#{@endpoint}#{ADMIN_URI_PATH}/#{path}")
  end

  private def s3_uri(path)
    URI.parse("#{@endpoint}/#{path}")
  end

  def admin_info
    send_request("GET", admin_uri("info"))
  end

  def admin_list_users
    response = send_request("GET", admin_uri("list-users"))
    JSON.parse @crypto.decrypt(response.data[:body], @creds[:secret_key])
  end

  def admin_add_user(access_key, secret_key)
    body_str = JSON.generate({"status" => "enabled", "secretKey" => secret_key}).encode("UTF-8")
    body = @crypto.encrypt(body_str, @creds[:secret_key])
    response = send_request("PUT", admin_uri("add-user?accessKey=#{access_key}"), body)
    response.status
  end

  def admin_remove_user(access_key)
    query = URI.encode_www_form({"accessKey" => access_key})
    response = send_request("DELETE", admin_uri("remove-user?#{query}"))
    response.status
  end

  def admin_policy_list
    send_request("GET", admin_uri("list-canned-policies"))
  end

  def admin_policy_add(policy_name, policy)
    body = JSON.generate(policy).encode("UTF-8")
    response = send_request("PUT", admin_uri("add-canned-policy?name=#{policy_name}"), body)
    response.status
  end

  def admin_policy_info(policy_name)
    send_request("GET", admin_uri("info-canned-policy?name=#{policy_name}"))
  end

  def admin_policy_set(policy_name, user_name)
    query = URI.encode_www_form({
      "userOrGroup" => user_name,
      "isGroup" => "false",
      "policyName" => policy_name
    })
    response = send_request("PUT", admin_uri("set-user-or-group-policy?#{query}"))
    response.data
  end

  def admin_policy_remove(policy_name)
    query = URI.encode_www_form({"name" => policy_name})
    response = send_request("DELETE", admin_uri("remove-canned-policy?#{query}"))
    response.status
  end

  def get_presigned_url(method, bucket_name, object_name, expires)
    @signer.presign_v4(method, s3_uri("#{bucket_name}/#{object_name}"), REGION, @creds, Time.now.utc, expires)
  end

  def create_bucket(bucket_name)
    response = send_request("PUT", s3_uri(bucket_name))
    response.status
  end

  def delete_bucket(bucket_name)
    response = send_request("DELETE", s3_uri(bucket_name))
    response.status
  end

  def bucket_exists?(bucket_name)
    response = send_request("GET", s3_uri(bucket_name))

    response.status == 200
  end

  def list_objects(bucket_name, folder_path, max_keys: 1000)
    objects = []
    query = URI.encode_www_form({
      "delimiter" => "",
      "encoding-type" => "url",
      "list-type" => 2,
      "prefix" => folder_path,
      "max-keys" => max_keys
    })
    response = send_request("GET", s3_uri("#{bucket_name}?#{query}"))
    if response.status == 404
      return objects
    end

    parsed_objects = parse_list_objects(response.data[:body])
    objects.concat(parsed_objects[0])

    is_truncated = parsed_objects[1]
    continuation_token = parsed_objects[2]
    while is_truncated
      query = URI.encode_www_form({
        "continuation-token" => continuation_token,
        "delimiter" => "",
        "encoding-type" => "url",
        "list-type" => 2,
        "prefix" => folder_path,
        "max-keys" => max_keys,
        "start-after" => continuation_token
      })
      response = send_request("GET", s3_uri("#{bucket_name}?#{query}"))
      parsed_objects = parse_list_objects(response.data[:body])
      objects.concat(parsed_objects[0])
      is_truncated = parsed_objects[1]
      continuation_token = parsed_objects[2]
    end

    objects
  end

  def set_lifecycle_policy(bucket_name, policy_id, expiration_days)
    raise "Error: policy_id must be all alphanumeric with the length between 5 and 32" unless /\A[a-z0-9]{5,32}\z/.match?(policy_id)
    raise "Error: expiration_days must be an integer between 0 and 999" unless expiration_days.is_a?(Integer) && expiration_days >= 0 && expiration_days <= 999
    policy = <<~LIFECYCLE_CONFIGURATION
<LifecycleConfiguration>
  <Rule>
    <ID>#{policy_id}</ID>
    <Status>Enabled</Status>
    <Filter></Filter>
    <Expiration>
      <Days>#{expiration_days}</Days>
    </Expiration>
  </Rule>
</LifecycleConfiguration>
    LIFECYCLE_CONFIGURATION
    response = send_request("PUT", s3_uri("#{bucket_name}?lifecycle"), policy, needs_md5: true)
    response.status
  end

  def send_request(method, uri, body = nil, needs_md5: false)
    headers = @signer.build_headers(method, uri, body, @creds, REGION, needs_md5)

    full_path = uri.path + (uri.query ? "?" + uri.query : "")
    response = @client.request(method: method, path: full_path, headers: headers, body: body)
    if [200, 204, 206, 404].include?(response.status)
      response
    else
      raise "Error: #{response.body}"
    end
  end

  private

  def parse_list_objects(response)
    # Parse the XML response
    doc = Nokogiri::XML(response)
    bucket_name = doc.xpath("//xmlns:Name").text
    encoding_type = doc.xpath("//xmlns:EncodingType").text
    # Process 'Contents' elements
    objects = doc.xpath("//xmlns:Contents").map do |node|
      Blob.from_xml(node, bucket_name, encoding_type: encoding_type)
    end

    # Note to future: We may need to process 'CommonPrefixes' elements
    # when we implement new APIs.
    is_truncated = doc.xpath("//xmlns:IsTruncated").text.casecmp("true").zero?
    continuation_token = doc.xpath("//xmlns:NextContinuationToken").text
    [objects, is_truncated, continuation_token]
  end

  class Blob
    attr_accessor :bucket_name, :key, :last_modified, :etag, :size,
      :version_id, :is_latest, :storage_class, :owner_id, :owner_name,
      :metadata, :is_delete_marker

    def initialize(bucket_name, object_name, last_modified: nil, etag: nil, size: nil,
      version_id: nil, is_latest: nil, storage_class: nil, owner_id: nil,
      owner_name: nil, metadata: {}, is_delete_marker: false)
      @bucket_name = bucket_name
      @key = object_name
      @last_modified = last_modified
      @etag = etag
      @size = size
      @version_id = version_id
      @is_latest = is_latest
      @storage_class = storage_class
      @owner_id = owner_id
      @owner_name = owner_name
      @metadata = metadata
      @is_delete_marker = is_delete_marker
    end

    def self.from_xml(element, bucket_name, encoding_type: nil, is_delete_marker: false)
      last_modified = element.at_xpath("xmlns:LastModified")&.text
      last_modified = Time.parse(last_modified) if last_modified
      etag = element.at_xpath("xmlns:ETag")&.text&.delete('"')
      size = element.at_xpath("xmlns:Size")&.text&.to_i
      owner = element.at_xpath("xmlns:Owner")
      owner_id = owner&.at_xpath("xmlns:ID")&.text
      owner_name = owner&.at_xpath("xmlns:DisplayName")&.text

      metadata = {}
      element.xpath("xmlns:UserMetadata").each do |child|
        key = child.name.split("}").last
        metadata[key] = child.text
      end

      key = element.at_xpath("xmlns:Key").text
      key = CGI.unescape(key) if encoding_type == "url"

      new(bucket_name, key, last_modified: last_modified, etag: etag, size: size,
        version_id: element.at_xpath("xmlns:VersionId")&.text,
        is_latest: element.at_xpath("xmlns:IsLatest")&.text,
        storage_class: element.at_xpath("xmlns:StorageClass")&.text,
        owner_id: owner_id, owner_name: owner_name, metadata: metadata,
        is_delete_marker: is_delete_marker)
    end
  end
end
