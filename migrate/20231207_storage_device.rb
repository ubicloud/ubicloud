# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:storage_device) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :total_storage_gib, :Integer, null: false
      column :available_storage_gib, :Integer, null: false
      column :enabled, :bool, null: false, default: true
      foreign_key :vm_host_id, :vm_host, type: :uuid
      unique [:vm_host_id, :name]
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :storage_device_id, :storage_device, type: :uuid, null: true
    end

    # Reuse corresponding VmHost's UBID as StorageDevice UBID and create
    # records for default storage devices on existing hosts.
    run <<~SQL
      INSERT INTO storage_device
        SELECT id, 'DEFAULT', total_storage_gib, available_storage_gib, true, id
        FROM vm_host;

      UPDATE vm_storage_volume
      SET storage_device_id = vm_host_id
      FROM vm
      WHERE vm_storage_volume.vm_id = vm.id;
    SQL
  end
end
