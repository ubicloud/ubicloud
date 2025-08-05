# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:aws_instance) do
      add_column :ipv4_dns_name, :text, null: true
    end
  end

  down do
    alter_table(:aws_instance) do
      drop_column :ipv4_dns_name
    end
  end
end
