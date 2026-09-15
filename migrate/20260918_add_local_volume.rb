# frozen_string_literal: true

Sequel.migration do
  change do
    # Local storage settings for volumes backed by a metal host's own disks.
    # Shares vm_storage_volume's primary key. Starts empty: existing rows keep
    # their settings in vm_storage_volume until they are copied over.
    create_table(:local_volume) do
      foreign_key :id, :vm_storage_volume, type: :uuid, primary_key: true, on_delete: :cascade
      foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid
      foreign_key :key_encryption_key_2_id, :storage_key_encryption_key, type: :uuid
      foreign_key :spdk_installation_id, :spdk_installation, type: :uuid
      foreign_key :storage_device_id, :storage_device, type: :uuid
      foreign_key :boot_image_id, :boot_image, type: :uuid
      foreign_key :machine_image_version_id, :machine_image_version, type: :uuid
      foreign_key :remote_storage_server_id, :remote_storage_server, type: :uuid
      foreign_key :vhost_block_backend_id, :vhost_block_backend, type: :uuid
      column :vring_workers, :integer
      column :use_bdev_ubi, :boolean, null: false, default: false
      column :track_written, :boolean, null: false, default: false
      column :max_read_mbytes_per_sec, :integer
      column :max_write_mbytes_per_sec, :integer

      constraint(:local_volume_single_source,
        Sequel.lit("(boot_image_id IS NOT NULL)::integer + (machine_image_version_id IS NOT NULL)::integer + (remote_storage_server_id IS NOT NULL)::integer <= 1"))
      constraint(:vring_workers_null_if_not_ubiblk,
        Sequel.lit("vhost_block_backend_id IS NOT NULL OR vring_workers IS NULL"))
      constraint(:vring_workers_positive_if_ubiblk,
        Sequel.lit("vhost_block_backend_id IS NULL OR (vring_workers IS NOT NULL AND vring_workers > 0)"))
    end
  end
end
