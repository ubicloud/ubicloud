# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:app_resource) do
      # Credential for the app's stream on the shared Parseable instance.
      # Encrypted at rest via the column_encryption plugin (see model).
      add_column :parseable_password, :text
    end
  end
end
