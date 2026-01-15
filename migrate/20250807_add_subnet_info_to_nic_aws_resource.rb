# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:nic_aws_resource) do
      add_column :subnet_id, :text
      add_column :subnet_az, :text
    end

    run "UPDATE nic_aws_resource SET subnet_id = psar.subnet_id FROM nic n JOIN private_subnet ps ON n.private_subnet_id = ps.id JOIN private_subnet_aws_resource psar ON ps.id = psar.id WHERE nic_aws_resource.id = n.id"
  end

  down do
    alter_table(:nic_aws_resource) do
      drop_column :subnet_id
      drop_column :subnet_az
    end
  end
end
