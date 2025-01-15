# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    %i[api_key firewall load_balancer minio_cluster private_subnet vm].each do |table|
      alter_table(table) do
        set_column_not_null :project_id
      end
    end
  end

  down do
    %i[api_key firewall load_balancer minio_cluster private_subnet vm].reverse_each do |table|
      alter_table(table) do
        set_column_allow_null :project_id
      end
    end
  end
end
