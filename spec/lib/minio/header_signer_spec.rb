# frozen_string_literal: true

RSpec.describe Minio::HeaderSigner do
  let(:headers) {
    {
      "Authorization" => "AWS4-HMAC-SHA256 Credential=access_key/20231130/us-east-1/s3/aws4_request, SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date, Signature=981fdbca705978113820de8f327062a9c20c1c9b6ecf3010f3124da3c95c450d",
      "Content-Length" => "4",
      "Content-Type" => "application/octet-stream",
      "Host" => "localhost:9000",
      "User-Agent" => "MinIO Ubicloud",
      "x-amz-content-sha256" => "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "x-amz-date" => "20231130T144358Z"
    }
  }

  describe "build_headers" do
    it "can build headers and sign with and without Content-Md5" do
      method = "PUT"
      uri = URI.parse("http://localhost:9000/test")
      body = "test"
      expect(Time).to receive(:now).and_return(Time.new("2023-11-30 15:43:58.612009 +0100")).at_least(:once)
      expect(described_class.new.build_headers(method, uri, body, {access_key: "access_key", secret_key: "secret_key"}, "us-east-1")).to eq(headers)
      expect(described_class.new.build_headers(method, uri, body, {access_key: "access_key", secret_key: "secret_key"}, "us-east-1", true)).to include("Content-Md5" => "CY9rzUYh03PK3k6DJie09g==")
    end
  end
end
