# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:private_subnet_aws_resource) do
      add_column :endpoint_security_group_id, :text, collate: '"C"'
    end
  end
end
