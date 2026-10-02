# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:cert) do
      add_column :expires_at, Time
    end
  end
end
