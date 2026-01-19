# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:persistent_storage_volume) do
      column :id, :uuid, primary_key: true
      column :project_id, :uuid, null: false

      # Before attaching to a VM, a volume may be stored on any host. When
      # attaching to a VM, it will be migrated to the VM's host.
      foreign_key :vm_host_id, :vm_host, type: :uuid
      foreign_key :vhost_block_backend_id, :vhost_block_backend, type: :uuid

      # If attached to a VM, this field references the VM storage volume. When
      # migrating between hosts, for a while vm_host_id and id of the host
      # containing the volume will differ. After catching up, they will be the
      # same again.
      foreign_key :vm_storage_volume_id, :vm_storage_volume, type: :uuid

      # Migration happens over an encrypted TCP connection.
      column :migration_port, Integer

      # Migration secrets are not stored in the database. They will be stored in
      # an encrypted form in the config files on the source and destination
      # hosts. We will use key encryption keys to encrypt those secrets. The
      # source host will use the following key. The destination host will use vm
      # storage_volume's key encryption key.
      foreign_key :key_encryption_key_id, :storage_key_encryption_key, type: :uuid

      column :name, String, null: false
      column :size_gib, Integer, null: false

      column :created_at, DateTime, null: false, default: Sequel.lit("CURRENT_TIMESTAMP")

      unique [:project_id, :name]
      unique [:vm_host_id, :migration_port]

      check Sequel.lit(
        "(vm_host_id IS NULL) = (vhost_block_backend_id IS NULL) AND " \
        "(vm_host_id IS NULL) = (key_encryption_key_id IS NULL)"
      )
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :persistent_storage_volume_id, :persistent_storage_volume, type: :uuid, null: true
    end
  end
end
