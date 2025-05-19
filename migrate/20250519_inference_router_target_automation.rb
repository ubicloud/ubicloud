# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:inference_router_target) do
      add_column :type, String, collate: '"C"', null: false, default: "manual"
      add_column :config, :jsonb, null: false, default: "{}"
      add_column :state, :jsonb, null: false, default: "{}"
    end
  end
end
