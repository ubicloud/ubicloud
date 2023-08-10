# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:private_subnet) do
      add_column :last_rekey_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
end
