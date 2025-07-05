# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:nic_aws_resource) do
      add_column :network_interface_id, :text
    end

    run <<~SQL
      UPDATE nic_aws_resource SET network_interface_id = (SELECT n.name FROM nic n WHERE n.id = nic_aws_resource.id);
    SQL
  end

  down do
    alter_table(:nic_aws_resource) do
      drop_column :network_interface_id
    end
  end
end
