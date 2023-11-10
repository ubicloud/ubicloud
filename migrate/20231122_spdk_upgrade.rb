# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:spdk_installation) do
      column :id, :uuid, primary_key: true
      column :version, :text, null: false
      column :allocation_weight, :Integer, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :vm_host_id, :vm_host, type: :uuid
      unique [:vm_host_id, :version]
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :spdk_installation_id, :spdk_installation, type: :uuid, null: true
    end

    # Reuse corresponding VmHost's UBID as SpdkInstallation UBID and create
    # records for legacy spdk installations on existing hosts.
    run <<~SQL
      INSERT INTO spdk_installation
        SELECT id, 'LEGACY_SPDK_VERSION', 100, now(), id
        FROM vm_host;

      UPDATE vm_storage_volume
      SET spdk_installation_id = vm_host_id
      FROM vm
      WHERE vm_storage_volume.vm_id = vm.id;
    SQL

    # Now that every volume has an installation, we can enforce NOT NULL.
    alter_table(:vm_storage_volume) do
      set_column_not_null :spdk_installation_id
    end
  end
end
