# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:private_subnet_aws_resource) do
      add_column :security_group_id, :text
    end
  end
end
