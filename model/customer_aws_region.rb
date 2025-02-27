# frozen_string_literal: true

require_relative "../model"

class CustomerAwsRegion < Sequel::Model
  include ResourceMethods
  many_to_one :project
  one_to_one :location

  plugin :column_encryption do |enc|
    enc.column :access_key
    enc.column :secret_key
  end

  def path
    "/region/#{ubid}"
  end

  def has_resources
    project.has_resources
  end
end

# Table: customer_aws_region
# Columns:
#  id         | uuid | PRIMARY KEY
#  access_key | text | NOT NULL
#  secret_key | text | NOT NULL
#  project_id | uuid | NOT NULL
# Indexes:
#  customer_aws_region_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  customer_aws_region_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  location | location_customer_aws_region_id_fkey | (customer_aws_region_id) REFERENCES customer_aws_region(id)
