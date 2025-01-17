# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:address) do
      add_column :gateway, :cidr, null: true
      add_column :mask, :int, null: true
    end
  end
end
