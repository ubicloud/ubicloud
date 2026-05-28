# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:nic_gcp_resource) do
      add_column :address_name, :text, collate: '"C"'
    end
  end
end
