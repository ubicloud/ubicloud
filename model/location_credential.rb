# frozen_string_literal: true

require_relative "../model"
require "aws-sdk-ec2"
require "aws-sdk-iam"
# :nocov:
require "aws-sdk-sts" if Config.test? ? ENV["CLOVER_FREEZE"] != "1" : Config.aws_postgres_iam_access
# :nocov:

class LocationCredential < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:access_key, :secret_key]
  many_to_one :project
  many_to_one :location, key: :id

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
    @iam_client ||= Aws::IAM::Client.new(region: location.name, credentials:)
  end

  def aws_iam_account_id
    @account_id ||= Aws::STS::Client.new(region: location.name, credentials:).get_caller_identity.account
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
