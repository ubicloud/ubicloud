# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:machine_image) do
      # UBID.to_base32_n("mi") => 641
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(641)")
      column :name, :text, null: false
      column :bucket_prefix, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :ready, :boolean, null: false, default: false

      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false

      index :project_id
      index :location_id
    end
  end
end
