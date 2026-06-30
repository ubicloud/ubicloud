# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:nic_aws_resource) do
      add_column :use_eip, :boolean, null: false, default: true
    end
  end
end
