# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:location) do
      add_column :dns_suffix, String
    end
  end
end
