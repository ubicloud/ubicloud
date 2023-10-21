# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:access_policy) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:access_tag) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:accounts) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:billing_info) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:payment_method) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
    alter_table(:project) do
      add_column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
end
