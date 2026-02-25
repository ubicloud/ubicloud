# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:location) do
      add_column :otel_otlp_export_endpoint, String
    end
  end

  down do
    alter_table(:location) do
      drop_column :otel_otlp_export_endpoint
    end
  end
end
