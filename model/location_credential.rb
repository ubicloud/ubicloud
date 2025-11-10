# frozen_string_literal: true

require_relative "../model"
require "aws-sdk-ec2"
require "aws-sdk-iam"

class LocationCredential < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:access_key, :secret_key]
  many_to_one :project
  many_to_one :location, key: :id

  def client
    Aws::EC2::Client.new(access_key_id: access_key, secret_access_key: secret_key, region: location.name)
  end

  def iam_client
    Aws::IAM::Client.new(access_key_id: access_key, secret_access_key: secret_key, region: location.name)
  end
end

# Table: location_credential
# Columns:
#  access_key  | text |
#  secret_key  | text |
#  id          | uuid | PRIMARY KEY
#  assume_role | text |
# Indexes:
#  location_credential_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  location_credential_single_auth_mechanism | (access_key IS NOT NULL AND secret_key IS NOT NULL AND assume_role IS NULL OR access_key IS NULL AND secret_key IS NULL AND assume_role IS NOT NULL)
# Foreign key constraints:
#  location_credential_id_fkey | (id) REFERENCES location(id)
