# frozen_string_literal: true

require_relative "../model"

class AwsLocationCredential < Sequel::Model
  include ResourceMethods
  many_to_one :project
  one_to_one :location

  plugin :column_encryption do |enc|
    enc.column :access_key
    enc.column :secret_key
  end

  def path
    "#{project.path}/aws-region/#{ubid}"
  end

  def has_resources
    project.postgres_resources_dataset.where(location_id: location.id).count > 0
  end

  def billing_location_name
    "aws-#{region_name.split("-")[..-2].join("-")}"
  end
end

# Table: aws_location_credential
# Columns:
#  id          | uuid | PRIMARY KEY
#  access_key  | text | NOT NULL
#  secret_key  | text | NOT NULL
#  region_name | text | NOT NULL
#  project_id  | uuid | NOT NULL
# Indexes:
#  aws_location_credential_pkey                       | PRIMARY KEY btree (id)
#  aws_location_credential_project_id_region_name_key | UNIQUE btree (project_id, region_name)
# Foreign key constraints:
#  aws_location_credential_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  location | location_aws_location_credential_id_fkey | (aws_location_credential_id) REFERENCES aws_location_credential(id)
