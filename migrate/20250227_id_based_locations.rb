# frozen_string_literal: true

Sequel.migration do
  up do
    %i[vm_host vm vm_pool private_subnet firewall postgres_resource minio_cluster inference_endpoint kubernetes_cluster].each do |table|
      alter_table(table) do
        add_foreign_key :location_id, :location, type: :uuid
      end

      from(table).update(location_id: from(:location)
        .where(name: Sequel[table][:location])
        .select(:id))
    end
  end

  down do
    %i[vm_host vm vm_pool private_subnet firewall postgres_resource minio_cluster inference_endpoint kubernetes_cluster].each do |table|
      from(table).update(location: from(:location)
        .where(id: Sequel[table][:location_id])
        .select(:name))

      alter_table(table) do
        drop_column :location_id
      end
    end
  end
end
