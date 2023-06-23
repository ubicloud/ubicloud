# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_private_subnet) do
      add_column :net4, :cidr, null: false
    end
  end
end