# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:page_snooze) do
      # UBID.to_base32_n("et") => 474
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(474)")
      foreign_key :page_id, :page, type: :uuid, null: false, on_delete: :cascade, index: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :snooze_until, :timestamptz, null: false
      column :snoozed_by, :text, null: false, collate: '"C"'
      column :note, :text, null: false, collate: '"C"'
    end
  end
end
