# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic_aws_resource) do
      # Whether Ubicloud creates the ENI before launch (to set the security
      # group and IPv6), as opposed to letting AWS create it at launch. This
      # was previously conflated with use_eip.
      add_column :create_network_interface, :boolean, null: false, default: true
    end
  end
end
