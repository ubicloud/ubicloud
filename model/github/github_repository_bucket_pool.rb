# frozen_string_literal: true

require_relative "../../model"

class GithubRepositoryBucketPool < Sequel::Model
  plugin ResourceMethods, encrypted_columns: :secret_key, etc_type: true
end

# Table: github_repository_bucket_pool
# Columns:
#  id         | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  access_key | text | NOT NULL
#  secret_key | text | NOT NULL
# Indexes:
#  github_repository_bucket_pool_pkey | PRIMARY KEY btree (id)
