# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:detachable_volume) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 443) # UBID.to_base32_n("dv")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :size_gib, Integer, null: false

      foreign_key :vm_host_id, :vm_host, type: :uuid

      foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid, null: false
      foreign_key :key_encryption_key_2_id, :storage_key_encryption_key, type: :uuid
      column :wrapped_xts, :text, collate: '"C"', null: false

      column :source_image, :text, collate: '"C"', null: false

      index [:vm_host_id], name: "detachable_volume_vm_host_id_idx"
    end
  end
end
