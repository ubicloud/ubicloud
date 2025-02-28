# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    %i[postgres_resource firewall private_subnet vm minio_cluster kubernetes_cluster].each do |table|
      add_index table, [:project_id, :location_id, :name], name: :"#{table}_project_id_location_id_name_uidx", unique: true, concurrently: true
    end
  end

  down do
    %i[postgres_resource firewall private_subnet vm minio_cluster kubernetes_cluster].each do |table|
      add_index table, [:project_id, :location, :name], name: :"#{table}_project_id_location_name_uidx", unique: true, concurrently: true
    end
  end
end
