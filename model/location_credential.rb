# frozen_string_literal: true

require_relative "../model"
require "aws-sdk-ec2"

class LocationCredential < Sequel::Model
  include ResourceMethods
  many_to_one :project
  many_to_one :location, key: :id
  plugin :column_encryption do |enc|
    enc.column :access_key
    enc.column :secret_key
  end

  def client
    Aws::EC2::Client.new(access_key_id: access_key, secret_access_key: secret_key, region: location.name)
  end
end

# Table: location_credential
# Columns:
#  access_key | text | NOT NULL
#  secret_key | text | NOT NULL
#  id         | uuid | PRIMARY KEY
# Indexes:
#  location_credential_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  location_credential_id_fkey | (id) REFERENCES location(id)
