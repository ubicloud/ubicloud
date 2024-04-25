# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:firewall) do
      drop_column :vm_id
    end
  end

  down do
    alter_table(:firewall) do
      add_foreign_key :vm_id, :vm, type: :uuid
    end
  end
end
