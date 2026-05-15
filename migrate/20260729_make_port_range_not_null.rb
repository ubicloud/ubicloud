# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:firewall_rule) do
      set_column_not_null :port_range
    end
  end
end
