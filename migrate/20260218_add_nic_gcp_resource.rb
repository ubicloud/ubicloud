# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:nic_gcp_resource) do
      foreign_key :id, :nic, type: :uuid, primary_key: true
      column :address_name, :text, collate: '"C"'
      column :static_ip, :inet
      column :vpc_name, :text, null: false, collate: '"C"'
      column :subnet_name, :text, null: false, collate: '"C"'
    end
  end
end
