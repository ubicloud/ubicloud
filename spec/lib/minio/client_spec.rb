# frozen_string_literal: true

RSpec.describe Minio::Client do
  let(:endpoint) { "https://localhost:9000" }
  let(:cert) { "-----BEGIN CERTIFICATE-----\nMIIDCzCCAfOgAwIBAgIUasLyHvpgRtp3/8N9pRPE7f89Gi4wDQYJKoZIhvcNAQEL\nBQAwFTETMBEGA1UEAwwKTXkgVGVzdCBDQTAeFw0yNTA2MDIwOTE2MjFaFw0zNTA1\nMzEwOTE2MjFaMBUxEzARBgNVBAMMCk15IFRlc3QgQ0EwggEiMA0GCSqGSIb3DQEB\nAQUAA4IBDwAwggEKAoIBAQC0WFDSoccSl95/VL4U73JYAYgg1ar96Mo9VJn5H+Y0\nvyfKUI7DWrqZtiqYlCr01nN52FFHwEBgCIYr+aa5MmMHZfe0nbeDK4AbsZKJHr0Z\nBfJfqI9pRxVd9MyRcU2XTAeDWRK3k3sRj6webU2MFxUvF7xB2Wx2+rNhLZhB+d8t\nZSRpwFiX9rgMKYkycY1kV4ZurUT72ct/Q+dNCTTUOel/brMDQhdn02PYAUKgh2UB\nELeooXt1JPedjSH41ShV2yEBA1NyTctaVp3tWfiq+b4p0ZiV/ekoBtkDe5WtaNo1\nxgvRGH/rcOfTraZKokgqCVCG1Ka4DrkvSsaTlOe9XrQlAgMBAAGjUzBRMB0GA1Ud\nDgQWBBQUnKN3Du3ihaNNK3Q9+lztEI4pajAfBgNVHSMEGDAWgBQUnKN3Du3ihaNN\nK3Q9+lztEI4pajAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAG\ndJijmtiYx2dCw50V3QhjyVyTvhFf1B9XUKGP2i0IPApULXqDGll47iIGo6i1yD7V\n7hjpV0BCtFlNH5nH2bZ0zyUi3XCLTqlnHM8+tI6ZUMWRq2lJAgILVHH/D/VUTUl6\nS+h6rGbtzNBCz2jmP3LiL2lmfcPivJpim5RPtAbApyt7fvHWD8aGQWZHpLYn+2v5\n1laUkm55cvWlsnC27PeNT00/3Eu96dqMiLHFJgKkUGFJMr+49X+BTaLcCUXCja+s\n4nXqhVt+iVVk1RtVS/b1C17DvxnV5g1NAFiZQOx5Gfsr5v8SafKCgR/4xm/kGfEz\nIkfEWqyeWXMj/JRB2yCy\n-----END CERTIFICATE-----" }
  let(:minio_client) { described_class.new(endpoint: endpoint, access_key: "minioadmin", secret_key: "minioadminpw", ssl_ca_data: cert) }

  it "can use ssl_ca_data" do
    excon_client = minio_client.instance_variable_get(:@client)
    expect(excon_client).to be_a(Excon::Connection)
    expect(excon_client.data[:ssl_cert_store]).to be_a(OpenSSL::X509::Store)
  end

  describe "admin_info" do
    it "sends a GET request to /minio/admin/v3/info" do
      stub_request(:get, "#{endpoint}/minio/admin/v3/info").to_return(status: 200, body: "test")

      expect(minio_client.admin_info.data[:body]).to eq("test")
    end
  end

  describe "admin_list_users" do
    it "sends a GET request to /minio/admin/v3/list-users" do
      crypto = instance_double(Minio::Crypto)
      stub_request(:get, "#{endpoint}/minio/admin/v3/list-users").to_return(status: 200, body: "test_encrypted")
      expect(Minio::Crypto).to receive(:new).and_return(crypto)
      expect(crypto).to receive(:decrypt).with("test_encrypted", "minioadminpw").and_return("{\"test\": \"test\"}")

      expect(minio_client.admin_list_users).to eq({"test" => "test"})
    end
  end

  describe "admin_add_user" do
    it "sends a PUT request to /minio/admin/v3/add-user" do
      crypto = instance_double(Minio::Crypto)
      stub_request(:put, "#{endpoint}/minio/admin/v3/add-user?accessKey=test").to_return(status: 200)
      expect(Minio::Crypto).to receive(:new).and_return(crypto)
      expect(crypto).to receive(:encrypt).with("{\"status\":\"enabled\",\"secretKey\":\"test\"}", "minioadminpw").and_return("test_encrypted")

      expect(minio_client.admin_add_user("test", "test")).to eq(200)
    end

    it "sends a PUT request but fails if user exists" do
      crypto = instance_double(Minio::Crypto)
      stub_request(:put, "#{endpoint}/minio/admin/v3/add-user?accessKey=test").to_return(status: 409)
      expect(Minio::Crypto).to receive(:new).and_return(crypto)
      expect(crypto).to receive(:encrypt).with("{\"status\":\"enabled\",\"secretKey\":\"test\"}", "minioadminpw").and_return("test_encrypted")

      expect {
        minio_client.admin_add_user("test", "test")
      }.to raise_error RuntimeError
    end
  end

  describe "admin_remove_user" do
    it "sends a DELETE request to /minio/admin/v3/remove-user" do
      stub_request(:delete, "#{endpoint}/minio/admin/v3/remove-user?accessKey=test").to_return(status: 200)

      expect(minio_client.admin_remove_user("test")).to eq(200)
    end
  end

  describe "admin_policy_list" do
    it "sends a GET request to /minio/admin/v3/list-canned-policies" do
      stub_request(:get, "#{endpoint}/minio/admin/v3/list-canned-policies").to_return(status: 200, body: "test")

      expect(minio_client.admin_policy_list.data[:body]).to eq("test")
    end
  end

  describe "admin_policy_add" do
    it "sends a PUT request to /minio/admin/v3/add-canned-policy" do
      stub_request(:put, "#{endpoint}/minio/admin/v3/add-canned-policy?name=test").to_return(status: 200)
      policy = {"Version" => "2012-10-17", "Statement" => [{"Action" => ["s3:GetBucketLocation"], "Effect" => "Allow", "Principal" => {"AWS" => ["*"]}, "Resource" => ["arn:aws:s3:::test"], "Sid" => ""}]}
      expect(minio_client.admin_policy_add("test", policy)).to eq(200)
    end
  end

  describe "admin_policy_info" do
    it "sends a GET request to /minio/admin/v3/info-canned-policy" do
      stub_request(:get, "#{endpoint}/minio/admin/v3/info-canned-policy?name=test").to_return(status: 200, body: "test")

      expect(minio_client.admin_policy_info("test").data[:body]).to eq("test")
    end
  end

  describe "admin_policy_set" do
    it "sends a PUT request to /minio/admin/v3/set-user-or-group-policy" do
      stub_request(:put, "#{endpoint}/minio/admin/v3/set-user-or-group-policy?userOrGroup=test&isGroup=false&policyName=test").to_return(status: 200)

      expect(minio_client.admin_policy_set("test", "test")).to eq({body: "", headers: {}, reason_phrase: "", remote_ip: "127.0.0.1", status: 200})
    end
  end

  describe "admin_policy_remove" do
    it "sends a DELETE request to /minio/admin/v3/remove-canned-policy" do
      stub_request(:delete, "#{endpoint}/minio/admin/v3/remove-canned-policy?name=test").to_return(status: 200)

      expect(minio_client.admin_policy_remove("test")).to eq(200)
    end
  end

  describe "put_bucket" do
    it "sends a PUT request to /bucket_name" do
      stub_request(:put, "#{endpoint}/test").to_return(status: 200)

      expect(minio_client.create_bucket("test")).to eq(200)
    end
  end

  describe "get_presigned_url" do
    it "creates a presigned URL for given object" do
      uri = minio_client.get_presigned_url("GET", "test", "object", 3600)
      expect(uri.to_s).to start_with(endpoint)
      expect(uri.path).to eq("/test/object")
      expect(uri.query).to match(/X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=minioadmin%2F\d{8}%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=\d{8}T\d{6}Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=\w+/)
    end
  end

  describe "delete_bucket" do
    it "sends a DELETE request to /bucket_name" do
      stub_request(:delete, "#{endpoint}/test").to_return(status: 200)

      expect(minio_client.delete_bucket("test")).to eq(200)
    end
  end

  describe "bucket_exists?" do
    it "sends a GET request to /bucket_name" do
      stub_request(:get, "#{endpoint}/test").to_return(status: 200)

      expect(minio_client.bucket_exists?("test")).to be(true)
    end

    it "returns false if the bucket does not exist" do
      stub_request(:get, "#{endpoint}/test").to_return(status: 404)

      expect(minio_client.bucket_exists?("test")).to be(false)
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
      expect(minio_client.list_objects("test", "folder_path", max_keys: 1).map(&:key)).to eq(["name1", "name2"])
    end

    it "returns empty list for non existent bucket" do
      stub_request(:get, "#{endpoint}/test?delimiter=&encoding-type=url&list-type=2&prefix=folder_path&max-keys=1").to_return(status: 404)
      expect(minio_client.list_objects("test", "folder_path", max_keys: 1)).to eq([])
    end
  end

  describe "set_lifecycle_policy" do
    it "raises exception on faulty input" do
      expect { minio_client.set_lifecycle_policy("test", "shrt", 8) }.to raise_error RuntimeError
      expect { minio_client.set_lifecycle_policy("test", "loooooooooooooooooooooooooooooooooooooooooooong", 8) }.to raise_error RuntimeError
      expect { minio_client.set_lifecycle_policy("test", "non-alphanumeric-character", 8) }.to raise_error RuntimeError
      expect { minio_client.set_lifecycle_policy("test", "testid", "non integer") }.to raise_error RuntimeError
      expect { minio_client.set_lifecycle_policy("test", "testid", -1) }.to raise_error RuntimeError
      expect { minio_client.set_lifecycle_policy("test", "testid", 1000) }.to raise_error RuntimeError
    end

    it "sends a PUT request to /bucket_name?lifecycle" do
      stub_request(:put, "#{endpoint}/test?lifecycle").to_return(status: 200)
      expect(minio_client.set_lifecycle_policy("test", "testid", 8)).to eq(200)
    end
  end
end
