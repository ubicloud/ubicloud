# frozen_string_literal: true

require_relative "../../model"

class InferenceRouterModel < Sequel::Model
  include ResourceMethods

  def self.from_model_name(name)
    first(model_name: name)
  end
end

# Table: inference_router_model
# Columns:
#  id                           | uuid                     | PRIMARY KEY
#  created_at                   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at                   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  model_name                   | text                     | NOT NULL
#  tags                         | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  visible                      | boolean                  | NOT NULL DEFAULT false
#  prompt_billing_resource      | text                     | NOT NULL
#  completion_billing_resource  | text                     | NOT NULL
#  project_inflight_limit       | integer                  | NOT NULL
#  project_prompt_tps_limit     | integer                  | NOT NULL
#  project_completion_tps_limit | integer                  | NOT NULL
# Indexes:
#  inference_router_model_pkey           | PRIMARY KEY btree (id)
#  inference_router_model_model_name_key | UNIQUE btree (model_name)
# Referenced By:
#  inference_router_target | inference_router_target_inference_router_model_id_fkey | (inference_router_model_id) REFERENCES inference_router_model(id)
