# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:annotation) do
      # UBID.to_base32_n("an") => 341
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(341)")
      column :description, :text
      column :related_resources, "uuid[]"
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
