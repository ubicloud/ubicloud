# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_resource) do
      set_column_default :hostname_version, "v3"
    end
  end

  down do
    alter_table(:postgres_resource) do
      set_column_default :hostname_version, "v2"
    end
  end
end
