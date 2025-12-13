# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:ssh_key_rotator) do
      # UBID.to_base32_n("sr") => 824
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(824)")
      foreign_key :sshable_id, :sshable, type: :uuid, null: false, unique: true, on_delete: :cascade
      column :next_rotation_at, :timestamptz, null: false, default: Sequel.function(:now)
    end
  end
end
