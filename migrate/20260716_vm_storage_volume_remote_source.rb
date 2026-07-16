# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_storage_volume) do
      # The remote storage server this volume streams its stripes from.
      add_foreign_key :remote_storage_server_id, :remote_storage_server, type: :uuid
      # A volume has at most one source: a base image, a machine image, or a
      # remote storage server.
      drop_constraint(:vm_storage_volume_single_source)
      add_constraint(
        :vm_storage_volume_single_source,
        "(boot_image_id IS NOT NULL)::int + (machine_image_version_id IS NOT NULL)::int + " \
        "(remote_storage_server_id IS NOT NULL)::int <= 1",
      )
    end
  end

  down do
    alter_table(:vm_storage_volume) do
      drop_constraint(:vm_storage_volume_single_source)
      add_constraint(
        :vm_storage_volume_single_source,
        "boot_image_id IS NULL OR machine_image_version_id IS NULL",
      )
      drop_column(:remote_storage_server_id)
    end
  end
end
