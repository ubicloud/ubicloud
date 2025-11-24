# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:location_credential) do
      add_column :assume_role, String
    end

    alter_table(:aws_instance) do
      add_column :iam_role, String
    end
  end
end
