# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:assigned_vm_address) do
      set_column_allow_null :address_id
    end
  end
end
