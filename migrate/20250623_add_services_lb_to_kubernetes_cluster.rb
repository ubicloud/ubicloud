# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_cluster) do
      add_foreign_key :services_lb_id, :load_balancer, type: :uuid, null: true
    end
  end
end
