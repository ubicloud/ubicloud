# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:inference_endpoint) do
      add_column :external_config, :jsonb, null: false, default: "{}"
    end

    alter_table(:inference_endpoint_replica) do
      add_column :external_state, :jsonb, null: false, default: "{}"
    end
  end
end
