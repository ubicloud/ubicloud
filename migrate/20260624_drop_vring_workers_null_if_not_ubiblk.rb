# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_storage_volume) do
      drop_constraint :vring_workers_null_if_not_ubiblk
    end
  end

  down do
    alter_table(:vm_storage_volume) do
      add_constraint :vring_workers_null_if_not_ubiblk, "vhost_block_backend_id IS NOT NULL OR vring_workers IS NULL"
    end
  end
end
