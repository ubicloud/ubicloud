# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:private_subnet_aws_resource) do
      drop_column :subnet_id
    end
  end

  down do
    alter_table(:private_subnet_aws_resource) do
      add_column :subnet_id, :text, unique: true
    end

    run "UPDATE private_subnet_aws_resource SET subnet_id = nar.subnet_id FROM nic_aws_resource nar JOIN nic n ON nar.id = n.id WHERE private_subnet_aws_resource.id = n.private_subnet_id"
  end
end
