# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:location_credential) do
      add_column :assume_role, String
    end

    alter_table(:aws_instance) do
      add_column :iam_role, String
    end

    run <<~SQL
      ALTER TABLE location_credential
        ALTER COLUMN access_key DROP NOT NULL,
        ALTER COLUMN secret_key DROP NOT NULL,
        ADD CONSTRAINT location_credential_single_auth_mechanism CHECK (
          (
            access_key IS NOT NULL AND
            secret_key IS NOT NULL AND
            assume_role IS NULL
          ) OR (
            access_key IS NULL AND
            secret_key IS NULL AND
            assume_role IS NOT NULL
          )
        );
    SQL
  end

  down do
    run <<~SQL
      ALTER TABLE location_credential
        ALTER COLUMN access_key SET NOT NULL,
        ALTER COLUMN secret_key SET NOT NULL,
        DROP CONSTRAINT location_credential_single_auth_mechanism;
    SQL

    alter_table(:location_credential) do
      drop_column :assume_role
    end

    alter_table(:aws_instance) do
      drop_column :iam_role
    end
  end
end
