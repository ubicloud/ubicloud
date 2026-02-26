# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic_gcp_resource) do
      add_column :network_name, :text
      add_column :subnet_name, :text
      add_column :subnet_tag, :text
    end
  end
end
