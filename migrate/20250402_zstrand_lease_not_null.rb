# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:strand) do
      set_column_allow_null :lease, false
    end
  end
end
