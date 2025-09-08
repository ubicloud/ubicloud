# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE vm_storage_volume vsv
      SET vring_workers = GREATEST(1, vm.vcpus / 2)
      FROM vm
      WHERE vsv.vm_id = vm.id
        AND vsv.vring_workers IS NULL
        AND vsv.vhost_block_backend_id IS NOT NULL;
    SQL

    alter_table(:vm_storage_volume) do
      add_constraint(:vring_workers_positive_if_ubiblk,
        Sequel.lit("vhost_block_backend_id IS NULL OR (vring_workers IS NOT NULL AND vring_workers > 0)"))
      add_constraint(:vring_workers_null_if_not_ubiblk,
        Sequel.lit("vhost_block_backend_id IS NOT NULL OR vring_workers IS NULL"))
    end
  end

  down do
    alter_table(:vm_storage_volume) do
      drop_constraint(:vring_workers_positive_if_ubiblk)
      drop_constraint(:vring_workers_null_if_not_ubiblk)
    end
  end
end
