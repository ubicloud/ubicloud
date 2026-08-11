# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:provider_ip_range) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(474)") # et ubid type (internal-only)
      foreign_key :location_id, :location, type: :uuid, null: false, on_delete: :cascade
      column :bucket_id, :text, null: false
      column :ip_version, :int2, null: false
      column :cidrs, "cidr[]", null: false, default: Sequel.pg_array([], :cidr)
      column :refreshed_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:ip_version_v4_or_v6, ip_version: [4, 6])
      unique [:location_id, :bucket_id, :ip_version]
      index :refreshed_at
    end
  end
end
