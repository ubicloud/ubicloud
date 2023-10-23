# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:dns_zone) do
      add_column :last_purged_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
end
