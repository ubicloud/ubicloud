# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:app_resource) do
      drop_column :target_vm_size
    end
  end

  down do
    alter_table(:app_resource) do
      add_column :target_vm_size, :text, null: false, default: "hobby-1"
    end
  end
end
