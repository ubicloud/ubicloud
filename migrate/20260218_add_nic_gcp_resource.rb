# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:nic_gcp_resource) do
      foreign_key :id, :nic, type: :uuid, primary_key: true
      column :address_name, :text
      column :static_ip, :text
    end
  end
end
