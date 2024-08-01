# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:certs_load_balancers) do
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, null: false
      foreign_key :cert_id, :cert, type: :uuid, null: false
      primary_key [:load_balancer_id, :cert_id]
    end

    create_enum(:lb_hc_protocol, %w[tcp http https])
    alter_table(:load_balancer) do
      add_column :health_check_protocol, :lb_hc_protocol, null: false, default: "http"
    end
  end
end
