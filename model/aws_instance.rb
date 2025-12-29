# frozen_string_literal: true

require_relative "../model"

class AwsInstance < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: aws_instance
# Columns:
#  id            | uuid | PRIMARY KEY
#  instance_id   | text |
#  az_id         | text |
#  ipv4_dns_name | text |
#  iam_role      | text |
# Indexes:
#  aws_instance_pkey | PRIMARY KEY btree (id)
