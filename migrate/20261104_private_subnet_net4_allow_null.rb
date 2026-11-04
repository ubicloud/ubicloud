# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:private_subnet) do
      set_column_allow_null :net4
    end
  end
end
