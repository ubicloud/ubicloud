# frozen_string_literal: true

Sequel.migration do
  change do
    add_column :api_key, :project_id, :uuid
    add_column :firewall, :project_id, :uuid
    add_column :load_balancer, :project_id, :uuid
    add_column :minio_cluster, :project_id, :uuid
    add_column :private_subnet, :project_id, :uuid
    add_column :vm, :project_id, :uuid
  end
end
