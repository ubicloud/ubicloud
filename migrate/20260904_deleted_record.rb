# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:deleted_record, partition_by: :deleted_at, partition_type: :range) do
      column :deleted_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :model_name, :text, null: false
      column :record_id, :uuid
      column :model_values, :jsonb, null: false

      index [:model_name, :deleted_at]
      index [:record_id], where: Sequel.~(record_id: nil)
      index [:deleted_at], type: :brin
    end

    create_table(:deleted_record_archive) do
      Date :day, primary_key: true
      column :opened_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :verified_at, :timestamptz
      column :dropped_at, :timestamptz
    end

    create_table(:deleted_record_archive_slice) do
      foreign_key :day, :deleted_record_archive, type: Date, null: false, on_delete: :cascade
      column :period, :tstzrange, null: false
      String :object_key, null: false, unique: true
      Bignum :row_count, null: false
      Bignum :bytes, null: false
      String :etag
      primary_key [:day, :period]

      constraint(:period_within_day, Sequel.lit("period <@ tstzrange(timezone('UTC', day::timestamp), timezone('UTC', (day + 1)::timestamp), '[)')"))
      exclude([[:period, "&&"]], using: :gist, name: :deleted_record_archive_slice_period_no_overlap)
    end
  end
end
