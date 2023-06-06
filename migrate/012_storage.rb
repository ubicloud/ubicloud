# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_storage) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :vm_id, :vm, type: :uuid, null: false
      column :boot, :bool, null: false
      column :size_gb, :int, null: false
      column :encrypted, :bool, null: false
      column :encryption_key, :text, collate: '"C"', null: false
    end
  end
end
