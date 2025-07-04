# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:aws_instance) do
      column :id, :uuid, primary_key: true
      column :instance_id, :text
      column :az_id, :text
    end
  end

  down do
    drop_table(:aws_instance)
  end
end
