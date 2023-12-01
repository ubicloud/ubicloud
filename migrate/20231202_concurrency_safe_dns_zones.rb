# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:dns_record) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      drop_index [:dns_zone_id, :name, :type, :data], concurrently: true
      add_index [:dns_zone_id, :name, :type, :data], concurrently: true
    end
  end

  down do
    alter_table(:dns_record) do
      drop_index [:dns_zone_id, :name, :type, :data], concurrently: true
      add_index [:dns_zone_id, :name, :type, :data], unique: true, where: Sequel.lit("NOT tombstoned"), concurrently: true
      drop_column :created_at
    end
  end
end
