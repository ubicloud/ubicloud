# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_metric_destination) do
      add_column :options, :text
      set_column_allow_null :username
      set_column_allow_null :password
    end
  end

  # Destinations authenticating through options cannot satisfy the restored
  # NOT NULL constraints, and lose their credentials with the column anyway.
  down do
    from(:postgres_metric_destination).where(Sequel.or(username: nil, password: nil)).delete

    alter_table(:postgres_metric_destination) do
      drop_column :options
      set_column_not_null :username
      set_column_not_null :password
    end
  end
end
