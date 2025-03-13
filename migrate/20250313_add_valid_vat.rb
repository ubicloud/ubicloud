# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_info) do
      add_column :valid_vat, :bool, null: true, default: nil
    end
  end
end
