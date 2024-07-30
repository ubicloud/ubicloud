# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:firewall) do
      set_column_not_null :location
    end
  end
end
