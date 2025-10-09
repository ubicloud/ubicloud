# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:load_balancer) do
      add_column :cert_enabled, :bool, default: false
    end

    run "UPDATE load_balancer SET cert_enabled = true WHERE health_check_protocol = 'https'"
  end

  down do
    alter_table(:load_balancer) do
      drop_column :cert_enabled
    end
  end
end
