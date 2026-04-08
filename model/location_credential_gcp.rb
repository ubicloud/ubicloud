# frozen_string_literal: true

require_relative "../model"
require "google/cloud/compute/v1"
require "google/cloud/storage"
require "google/apis/cloudresourcemanager_v3"
require "google/apis/iam_v1"
require "googleauth"

class LocationCredentialGcp < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_LOCATION, encrypted_columns: [:credentials_json]
  many_to_one :location, key: :id

  def parsed_credentials
    @parsed_credentials ||= JSON.parse(credentials_json)
  end

  def zones_client
    @zones_client ||= Google::Cloud::Compute::V1::Zones::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def subnetworks_client
    @subnetworks_client ||= Google::Cloud::Compute::V1::Subnetworks::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def zone_operations_client
    @zone_operations_client ||= Google::Cloud::Compute::V1::ZoneOperations::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def region_operations_client
    @region_operations_client ||= Google::Cloud::Compute::V1::RegionOperations::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def global_operations_client
    @global_operations_client ||= Google::Cloud::Compute::V1::GlobalOperations::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def addresses_client
    @addresses_client ||= Google::Cloud::Compute::V1::Addresses::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def compute_client
    @compute_client ||= Google::Cloud::Compute::V1::Instances::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def network_firewall_policies_client
    @network_firewall_policies_client ||= Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def crm_client
    @crm_client ||= begin
      client = Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(credentials_json),
        scope: "https://www.googleapis.com/auth/cloud-platform"
      )
      client
    end
  end

  def networks_client
    @networks_client ||= Google::Cloud::Compute::V1::Networks::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def regional_crm_client(region)
    @regional_crm_clients ||= {}
    @regional_crm_clients[region] ||= begin
      client = Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService.new
      client.root_url = "https://#{region}-cloudresourcemanager.googleapis.com/"
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(credentials_json),
        scope: "https://www.googleapis.com/auth/cloud-platform"
      )
      client
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
