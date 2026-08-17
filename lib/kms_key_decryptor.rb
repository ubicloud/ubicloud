# frozen_string_literal: true

module KmsKeyDecryptor
  def self.aws_kms(key_id, ciphertext)
    require "aws-sdk-kms"
    Aws::KMS::Client.new.decrypt(ciphertext_blob: ciphertext, key_id:).plaintext
  end

  def self.gcp_kms(key_id, ciphertext)
    require "google/apis/cloudkms_v1"
    require "googleauth"
    kms = Google::Apis::CloudkmsV1::CloudKMSService.new
    kms.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloudkms"])
    kms.decrypt_crypto_key(key_id, Google::Apis::CloudkmsV1::DecryptRequest.new(ciphertext:)).plaintext
  end
end
