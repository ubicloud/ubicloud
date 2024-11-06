# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:lb_stack, %w[ipv4 ipv6 dual])

    alter_table(:load_balancer) do
      add_column :stack, :lb_stack, null: false, default: "dual"
    end
  end
end
