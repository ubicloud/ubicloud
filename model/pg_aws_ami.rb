# frozen_string_literal: true

require_relative "../model"

class PgAwsAmi < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: pg_aws_ami
# Columns:
#  id                | uuid | PRIMARY KEY
#  aws_location_name | text |
#  aws_ami_id        | text |
#  pg_version        | text |
#  arch              | text | NOT NULL
# Indexes:
#  pg_aws_ami_pkey                                    | PRIMARY KEY btree (id)
#  pg_aws_ami_aws_location_name_pg_version_arch_index | UNIQUE btree (aws_location_name, pg_version, arch)
