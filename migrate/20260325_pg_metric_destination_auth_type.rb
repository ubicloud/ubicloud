# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_metric_destination) do
      add_column :auth_type, :text, null: false, default: "basic"
      set_column_allow_null :username
    end
  end

  down do
    alter_table(:postgres_metric_destination) do
      drop_column :auth_type
      set_column_not_null :username
    end
  end
end
