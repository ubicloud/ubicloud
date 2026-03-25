# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:address) do
      add_column :gateway, :text, null: true
      add_column :mask, :integer, null: true
    end
  end
end
