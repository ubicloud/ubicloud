# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :ipv6_disabled, :boolean, null: false, default: false
    end
  end
end
