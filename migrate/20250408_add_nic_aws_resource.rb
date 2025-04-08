# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:nic_aws_resource) do
      foreign_key :id, :nic, type: :uuid, primary_key: true
      column :eip_allocation_id, :text
    end
  end
end
