# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vpc_peering_gcp_resource) do
      foreign_key :id, :vpc_peering, type: :uuid, primary_key: true
      column :peering_name, :text, collate: '"C"', null: false
    end
  end
end
