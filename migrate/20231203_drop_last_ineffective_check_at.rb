# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_timeline) do
      drop_column :last_ineffective_check_at
    end
  end

  down do
    alter_table(:postgres_timeline) do
      add_column :last_ineffective_check_at, :timestamptz
    end
  end
end
