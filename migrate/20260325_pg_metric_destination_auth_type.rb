# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_metric_destination) do
      add_column :auth_type, :text, null: false, default: "basic"
      add_column :mtls, :bool, null: false, default: false
      set_column_allow_null :username
    end
  end

  down do
    alter_table(:postgres_metric_destination) do
      drop_column :auth_type
      drop_column :mtls
      set_column_not_null :username
    end
  end
end
