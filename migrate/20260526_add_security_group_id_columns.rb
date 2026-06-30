# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:private_subnet_aws_resource) do
      add_column :mgmt_security_group_id, :text
      add_column :user_security_group_id, :text
    end
  end
end
