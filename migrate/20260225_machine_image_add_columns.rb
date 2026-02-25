# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:machine_image) do
      add_column :encrypted, TrueClass, null: false, default: true
      add_column :compression, String, null: false, default: "zstd"
      add_column :active, TrueClass, null: false, default: true
      add_column :decommissioned_at, :timestamptz
      set_column_allow_null :key_encryption_key_1_id
    end

    # Change version from integer to text
    alter_table(:machine_image) do
      set_column_type :version, String, using: Sequel.lit("'v' || version::text")
    end

    # Add source_fetch_total column to vm_storage_volume if not present
    unless DB.schema(:vm_storage_volume).any? { |col, _| col == :source_fetch_total }
      alter_table(:vm_storage_volume) do
        add_column :source_fetch_total, :bigint
        add_column :source_fetch_fetched, :bigint
      end
    end
  end

  down do
    alter_table(:vm_storage_volume) do
      drop_column :source_fetch_total if DB.schema(:vm_storage_volume).any? { |col, _| col == :source_fetch_total }
      drop_column :source_fetch_fetched if DB.schema(:vm_storage_volume).any? { |col, _| col == :source_fetch_fetched }
    end

    alter_table(:machine_image) do
      set_column_type :version, Integer, using: Sequel.lit("REPLACE(version, 'v', '')::integer")
      set_column_not_null :key_encryption_key_1_id
      drop_column :decommissioned_at
      drop_column :active
      drop_column :compression
      drop_column :encrypted
    end
  end
end
