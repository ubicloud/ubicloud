# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:kubernetes_vm) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :vm_id, :uuid, null: false

      foreign_key [:vm_id], :vm, key: :id, on_delete: :cascade
    end
  end
end
