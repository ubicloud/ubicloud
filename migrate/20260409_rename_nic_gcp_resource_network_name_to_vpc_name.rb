# frozen_string_literal: true

Sequel.migration do
  change do
    rename_column :nic_gcp_resource, :network_name, :vpc_name
  end
end
