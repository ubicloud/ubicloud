# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_init_script) do
      foreign_key :id, :vm, type: :uuid, primary_key: true
      column :script, String, size: 2000, null: false
    end
  end
end
