# frozen_string_literal: true

Sequel.migration do
  revert do
    %i[
      postgres_resource
      postgres_server
      postgres_timeline
      inference_endpoint
      inference_router
      inference_router_model
      inference_router_target
    ].each do |table|
      alter_table(table) do
        add_column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      end
    end
  end
end
