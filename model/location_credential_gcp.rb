# frozen_string_literal: true

require_relative "../model"
require "google/cloud/compute/v1"
require "google/cloud/storage"
require "google/apis/iam_v1"
require "googleauth"

class LocationCredentialGcp < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:credentials_json]
  many_to_one :location, key: :id

  def parsed_credentials
    @parsed_credentials ||= JSON.parse(credentials_json)
  end

  def compute_client
    @compute_client ||= Google::Cloud::Compute::V1::Instances::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def zones_client
    @zones_client ||= Google::Cloud::Compute::V1::Zones::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def storage_client
    @storage_client ||= Google::Cloud::Storage.new(
      project_id:,
      credentials: parsed_credentials
    )
  end

  def iam_client
    @iam_client ||= begin
      client = Google::Apis::IamV1::IamService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(credentials_json),
        scope: "https://www.googleapis.com/auth/cloud-platform"
      )
      client
    end
  end
end

# Table: location_credential_gcp
# Columns:
#  id                    | uuid | PRIMARY KEY
#  project_id            | text | NOT NULL
#  service_account_email | text | NOT NULL
#  credentials_json      | text | NOT NULL
# Indexes:
#  location_credential_gcp_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  location_credential_gcp_id_fkey | (id) REFERENCES location(id)
