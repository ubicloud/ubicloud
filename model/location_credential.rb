# frozen_string_literal: true

require_relative "../model"
require "aws-sdk-ec2"
require "aws-sdk-iam"
require "aws-sdk-sts"

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
    Aws::EC2::Client.new(region: location.name, credentials:)
  end

  def iam_client
    Aws::IAM::Client.new(region: location.name, credentials:)
  end

  def aws_iam_account_id
    @account_id ||= Aws::STS::Client.new(region: location.name, credentials:).get_caller_identity.account
  end
end

# Table: location_credential
# Columns:
#  access_key  | text | NOT NULL
#  secret_key  | text | NOT NULL
#  id          | uuid | PRIMARY KEY
#  assume_role | text |
# Indexes:
#  location_credential_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  location_credential_id_fkey | (id) REFERENCES location(id)
