# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :has_customer_data, :boolean, null: false, default: false
    end
  end
end
