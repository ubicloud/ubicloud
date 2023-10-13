# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:dns_zone) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :project_id, :project, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
    end

    create_table(:dns_record) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :dns_zone_id, :dns_zone, type: :uuid
      column :name, :text, collate: '"C"', null: false
      column :type, :text, collate: '"C"', null: false
      column :ttl, :bigint, null: false
      column :data, :text, collate: '"C"', null: false
      column :tombstoned, :boolean, null: false, default: false
      index [:dns_zone_id, :name, :type, :data], unique: true, where: Sequel.lit("NOT tombstoned")
    end
  end
end
