# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vhost_block_backend) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 474) # "et" ubid type
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :version, :text, null: false
      column :allocation_weight, :integer, null: false
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      unique [:vm_host_id, :version]
      check { allocation_weight >= 0 }
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :vhost_block_backend_id, :vhost_block_backend, type: :uuid, null: true
    end
  end
end
