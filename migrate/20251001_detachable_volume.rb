# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:detachable_volume) do
      column :id, :uuid, primary_key: true
      column :project_id, :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid

      foreign_key :source_vhost_block_backend_id, :vhost_block_backend, type: :uuid
      foreign_key :source_key_encryption_key_id, :storage_key_encryption_key, type: :uuid

      foreign_key :target_vhost_block_backend_id, :vhost_block_backend, type: :uuid
      foreign_key :target_key_encryption_key_id, :storage_key_encryption_key, type: :uuid

      column :name, String, null: false
      column :size_gib, Integer, null: false
      column :max_read_mbytes_per_sec, Integer
      column :max_write_mbytes_per_sec, Integer
      column :vring_workers, Integer
    end
  end
end
