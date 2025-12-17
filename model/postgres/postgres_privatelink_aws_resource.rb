# frozen_string_literal: true

require_relative "../../model"

class PostgresPrivatelinkAwsResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :postgres_resource

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :update_target

  def location
    postgres_resource.location
  end

  def display_state
    return "deleting" if destroy_set? || strand.nil? || strand.label == "destroy"
    return "available" if strand.label == "wait"

    "creating"
  end
end

# Table: postgres_privatelink_aws_resource
# Columns:
#  id                   | uuid                     | PRIMARY KEY
#  created_at           | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at           | timestamp with time zone | NOT NULL DEFAULT now()
#  postgres_resource_id | uuid                     | NOT NULL
#  nlb_arn              | text                     |
#  target_group_arn     | text                     |
#  listener_arn         | text                     |
#  service_id           | text                     |
#  service_name         | text                     |
# Indexes:
#  postgres_privatelink_aws_resource_pkey                     | PRIMARY KEY btree (id)
#  postgres_privatelink_aws_resource_postgres_resource_id_idx | UNIQUE btree (postgres_resource_id)
# Foreign key constraints:
#  postgres_privatelink_aws_resource_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
