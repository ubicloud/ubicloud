# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:storage_key_encryption_key) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :algorithm, :text, null: false, collate: '"C"'
      column :key, :text, null: false
      column :init_vector, :text, null: false
      column :auth_data, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    alter_table(:vm_storage_volume) do
      add_foreign_key :key_encryption_key_1_id, :storage_key_encryption_key, type: :uuid, null: true
      add_foreign_key :key_encryption_key_2_id, :storage_key_encryption_key, type: :uuid, null: true
    end
  end
end
