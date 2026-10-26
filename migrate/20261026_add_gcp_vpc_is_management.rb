# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:gcp_vpc) do
      add_column :is_management, :boolean, null: false, default: false
    end
  end
end
