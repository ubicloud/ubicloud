# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:remote_storage_server) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 793) # UBID.to_base32_n("rs")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      # The pre-shared key (and its TLS-PSK identity) securing the remote stripe
      # protocol connection. :psk is encrypted at the application layer.
      column :psk, :text, collate: '"C"', null: false
      column :psk_identity, :text, collate: '"C"', null: false
      column :port, Integer, null: false
      # The volume this server serves over the remote stripe protocol.
      foreign_key :source_vm_storage_volume_id, :vm_storage_volume, type: :uuid, null: false
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false

      index [:vm_host_id, :port], unique: true, name: "remote_storage_server_vm_host_id_port_uidx"
    end

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

    drop_table(:remote_storage_server)
  end
end
