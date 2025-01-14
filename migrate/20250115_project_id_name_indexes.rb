# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    %i[postgres_resource firewall private_subnet vm minio_cluster].each do |table|
      add_index table, [:project_id, :location, :name], name: :"#{table}_project_id_location_name_uidx", unique: true, concurrently: true
    end

    %i[dns_zone usage_alert].each do |table|
      add_index table, [:project_id, :name], name: :"#{table}_project_id_name_uidx", unique: true, concurrently: true
    end

    add_index :load_balancer, [:private_subnet_id, :name], name: :load_balancer_private_subnet_id_name_uidx, unique: true, concurrently: true

    alter_table(:postgres_resource) do
      drop_constraint :postgres_server_server_name_key
    end

    %i[api_key firewall load_balancer minio_cluster private_subnet vm].each do |table|
      alter_table(table) do
        add_foreign_key [:project_id], :project, name: :"#{table}_project_id_fkey"
      end
    end
  end

  down do
    %i[api_key firewall load_balancer minio_cluster private_subnet vm].reverse_each do |table|
      alter_table(table) do
        drop_constraint :"#{table}_project_id_fkey"
      end
    end

    alter_table(:postgres_resource) do
      add_unique_constraint :name, name: :postgres_server_server_name_key
    end

    drop_index :load_balancer, [:private_subnet_id, :name], name: :load_balancer_private_subnet_id_name_uidx, unique: true, concurrently: true

    %i[dns_zone usage_alert].reverse_each do |table|
      drop_index table, [:project_id, :name], name: :"#{table}_project_id_name_uidx", unique: true, concurrently: true
    end

    %i[postgres_resource firewall private_subnet vm minio_cluster].reverse_each do |table|
      drop_index table, [:project_id, :location, :name], name: :"#{table}_project_id_location_name_uidx", unique: true, concurrently: true
    end
  end
end
