# frozen_string_literal: true

Sequel.migration do
  up do
    %i[vm_host vm vm_pool private_subnet firewall postgres_resource minio_cluster inference_endpoint kubernetes_cluster].each do |table|
      alter_table(table) do
        drop_column :location
        set_column_not_null :location_id
      end
    end
  end

  down do
    %i[vm_host vm vm_pool private_subnet firewall postgres_resource minio_cluster inference_endpoint kubernetes_cluster].each do |table|
      alter_table(table) do
        add_column :location, :text
        set_column_allow_null :location_id
      end
    end
  end
end
