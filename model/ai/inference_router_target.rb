# frozen_string_literal: true

require_relative "../../model"

class InferenceRouterTarget < Sequel::Model
  many_to_one :inference_router
  many_to_one :inference_router_model

  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :api_key
  end
end

# Table: inference_router_target
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at                | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  name                      | text                     | NOT NULL
#  host                      | text                     | NOT NULL
#  api_key                   | text                     | NOT NULL
#  inflight_limit            | integer                  | NOT NULL
#  priority                  | integer                  | NOT NULL
#  extra_configs             | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  enabled                   | boolean                  | NOT NULL DEFAULT false
#  inference_router_model_id | uuid                     | NOT NULL
#  inference_router_id       | uuid                     | NOT NULL
#  type                      | text                     | NOT NULL DEFAULT 'manual'::text
#  config                    | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  state                     | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
# Indexes:
#  inference_router_target_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  inference_router_target_inference_router_id_fkey       | (inference_router_id) REFERENCES inference_router(id)
#  inference_router_target_inference_router_model_id_fkey | (inference_router_model_id) REFERENCES inference_router_model(id)
