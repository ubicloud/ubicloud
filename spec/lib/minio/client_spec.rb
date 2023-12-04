# frozen_string_literal: true

RSpec.describe Minio::Client do
  let(:endpoint) { "http://localhost:9000" }
  let(:access_key) { "minioadmin" }
  let(:secret_key) { "minioadmin" }


  describe "put_bucket" do
    it "sends a PUT request to /bucket_name" do
      stub_request(:put, "#{endpoint}/test").to_return(status: 200)

      expect(described_class.new(endpoint: endpoint, access_key: access_key, secret_key: secret_key).create_bucket("test")).to eq(200)
    end
  end

  describe "delete_bucket" do
    it "sends a DELETE request to /bucket_name" do
      stub_request(:delete, "#{endpoint}/test").to_return(status: 200)

      expect(described_class.new(endpoint: endpoint, access_key: access_key, secret_key: secret_key).delete_bucket("test")).to eq(200)
    end
  end

  describe "bucket_exists?" do
    it "sends a GET request to /bucket_name" do
      stub_request(:get, "#{endpoint}/test").to_return(status: 200)

      expect(described_class.new(endpoint: endpoint, access_key: access_key, secret_key: secret_key).bucket_exists?("test")).to be(true)
    end

    it "returns false if the bucket does not exist" do
      stub_request(:get, "#{endpoint}/test").to_return(status: 404)

      expect(described_class.new(endpoint: endpoint, access_key: access_key, secret_key: secret_key).bucket_exists?("test")).to be(false)
    end
  end

  describe "list_objects" do
    let(:xml_with_continuation_token) do
      <<~XML
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>vers</Name>
  <Prefix>Screenshot</Prefix>
  <NextContinuationToken>ct</NextContinuationToken>
  <KeyCount>1</KeyCount>
  <MaxKeys>1</MaxKeys>
  <IsTruncated>true</IsTruncated>
  <Contents>
    <Key>name1</Key>
    <ETag>&#34;49fda56ffd02844cd6c10effc3a69375&#34;</ETag>
    <StorageClass>STANDARD</StorageClass>
    <UserMetadata>
      <content-type>image/png</content-type>
      <x-amz-object-lock-mode>COMPLIANCE</x-amz-object-lock-mode>
      <x-amz-object-lock-retain-until-date>2023-12-02T10:46:35.273Z</x-amz-object-lock-retain-until-date>
    </UserMetadata>
  </Contents>
  <EncodingType>url</EncodingType>
</ListBucketResult>
      XML
    end

    let(:xml_without_continuation_token) do
      <<~XML
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>vers</Name>
  <Prefix>Screenshot</Prefix>
  <KeyCount>1</KeyCount>
  <MaxKeys>1</MaxKeys>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>name2</Key>
    <LastModified>2023-12-01T10:46:32.832Z</LastModified>
    <Size>1144893</Size>
    <Owner>
      <ID>minioadmin</ID>
      <DisplayName>minioadmin</DisplayName>
    </Owner>
    <VersionId>1</VersionId>
    <IsLatest>true</IsLatest>
  </Contents>
</ListBucketResult>
      XML
    end

    it "properly lists objects with or without continuation-token" do
      stub_request(:get, "#{endpoint}/test?delimiter=&encoding-type=url&list-type=2&prefix=folder_path&max-keys=1").to_return(status: 200, body: xml_with_continuation_token)
      stub_request(:get, "#{endpoint}/test?continuation-token=ct&delimiter=&encoding-type=url&list-type=2&prefix=folder_path&max-keys=1&start-after=ct").to_return(status: 200, body: xml_without_continuation_token)
      mc = described_class.new(endpoint: endpoint, access_key: access_key, secret_key: secret_key)
      expect(mc.list_objects("test", "folder_path", max_keys: 1).map(&:key)).to eq(["name1", "name2"])
    end
  end
end
