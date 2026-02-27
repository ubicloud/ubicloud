# frozen_string_literal: true

require_relative "../model"
require "aws-sdk-ec2"
require "aws-sdk-iam"
require "google/cloud/compute/v1"
require "google/cloud/storage"
require "google/apis/iam_v1"
require "googleauth"

class LocationCredential < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:access_key, :secret_key, :credentials_json]
  many_to_one :location, key: :id

  # AWS credential methods

  def credentials
    @credentials ||= if assume_role
      Aws::AssumeRoleCredentials.new(role_arn: assume_role, role_session_name: Config.aws_role_session_name)
    else
      Aws::Credentials.new(access_key, secret_key)
    end
  end

  def client
    @client ||= Aws::EC2::Client.new(region: location.name, credentials:)
  end

  def iam_client
    @iam_client ||= if credentials_json
      gcp_iam_client
    else
      Aws::IAM::Client.new(region: location.name, credentials:)
    end
  end

  def aws_iam_account_id
    @account_id ||= Aws::STS::Client.new(region: location.name, credentials:).get_caller_identity.account
  end

  # GCP credential methods

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

  def firewalls_client
    @firewalls_client ||= Google::Cloud::Compute::V1::Firewalls::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def network_firewall_policies_client
    @network_firewall_policies_client ||= Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def networks_client
    @networks_client ||= Google::Cloud::Compute::V1::Networks::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def subnetworks_client
    @subnetworks_client ||= Google::Cloud::Compute::V1::Subnetworks::Rest::Client.new do |config|
      config.credentials = parsed_credentials
    end
  end

  def addresses_client
    @addresses_client ||= Google::Cloud::Compute::V1::Addresses::Rest::Client.new do |config|
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

  private

  def gcp_iam_client
    @gcp_iam_client ||= begin
      client = Google::Apis::IamV1::IamService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(credentials_json),
        scope: "https://www.googleapis.com/auth/cloud-platform"
      )
      client
    end
  end
end

# Table: location_credential
# Columns:
#  access_key            | text |
#  secret_key            | text |
#  id                    | uuid | PRIMARY KEY
#  assume_role           | text |
#  project_id            | text |
#  service_account_email | text |
#  credentials_json      | text |
# Indexes:
#  location_credential_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  location_credential_single_auth_mechanism | (access_key IS NOT NULL AND secret_key IS NOT NULL AND assume_role IS NULL AND credentials_json IS NULL OR access_key IS NULL AND secret_key IS NULL AND assume_role IS NOT NULL AND credentials_json IS NULL OR access_key IS NULL AND secret_key IS NULL AND assume_role IS NULL AND credentials_json IS NOT NULL AND project_id IS NOT NULL AND service_account_email IS NOT NULL)
# Foreign key constraints:
#  location_credential_id_fkey | (id) REFERENCES location(id)
