# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:load_balancer) do
      set_column_default :hostname_version, 2
    end
  end

  down do
    alter_table(:load_balancer) do
      set_column_default :hostname_version, 1
    end
  end
end
