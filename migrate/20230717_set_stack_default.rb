# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:strand) do
      set_column_default(:stack, "[{}]")
    end
  end

  down do
    alter_table(:strand) do
      set_column_default(:stack, "[]")
    end
  end
end
