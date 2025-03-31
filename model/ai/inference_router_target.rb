# frozen_string_literal: true

require_relative "../../model"

class InferenceRouterTarget < Sequel::Model
  many_to_one :inference_router

  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :api_key
  end
end

# Table: inference_router_target
# Columns:
#  id                  | uuid                     | PRIMARY KEY
#  created_at          | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at          | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  name                | text                     | NOT NULL
#  model_name          | text                     | NOT NULL
#  host                | text                     | NOT NULL
#  api_key             | text                     | NOT NULL
#  inflight_limit      | integer                  | NOT NULL
#  priority            | integer                  | NOT NULL
#  tags                | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  inference_router_id | uuid                     | NOT NULL
# Indexes:
#  inference_router_target_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  inference_router_target_inference_router_id_fkey | (inference_router_id) REFERENCES inference_router(id)
