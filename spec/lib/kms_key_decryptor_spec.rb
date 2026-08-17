# frozen_string_literal: true

require_relative "../spec_helper"
require "aws-sdk-kms"
require "google/apis/cloudkms_v1"
require "googleauth"

RSpec.describe KmsKeyDecryptor do
  let(:ciphertext) { "\x01\x02ciphertext-bytes".b }
  let(:plaintext) { "\x03\x04plaintext-bytes".b }

  it "decrypts via AWS KMS" do
    key_id = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
    client = instance_double(Aws::KMS::Client)
    expect(Aws::KMS::Client).to receive(:new).and_return(client)
    expect(client).to receive(:decrypt).with(ciphertext_blob: ciphertext, key_id:).and_return(instance_double(Aws::KMS::Types::DecryptResponse, plaintext:))
    expect(described_class.aws_kms(key_id, ciphertext)).to eq(plaintext)
  end

  it "decrypts via GCP Cloud KMS" do
    key_id = "projects/test-project/locations/us-central1/keyRings/test-ring/cryptoKeys/test-key"
    kms = instance_double(Google::Apis::CloudkmsV1::CloudKMSService)
    authorization = instance_double(Google::Auth::ServiceAccountCredentials)
    expect(Google::Apis::CloudkmsV1::CloudKMSService).to receive(:new).and_return(kms)
    expect(Google::Auth).to receive(:get_application_default).with(["https://www.googleapis.com/auth/cloudkms"]).and_return(authorization)
    expect(kms).to receive(:authorization=).with(authorization)
    expect(kms).to receive(:decrypt_crypto_key) do |name, request|
      expect(name).to eq(key_id)
      expect(request).to be_a(Google::Apis::CloudkmsV1::DecryptRequest)
      expect(request.ciphertext).to eq(ciphertext)
      Google::Apis::CloudkmsV1::DecryptResponse.new(plaintext:)
    end
    expect(described_class.gcp_kms(key_id, ciphertext)).to eq(plaintext)
  end
end
