# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_cluster) do
      add_column :csi_config, :jsonb, null: false, default: "{}"
    end
  end
end
