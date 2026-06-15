# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:app_resource) do
      # Optional app-owned managed Postgres (in the app service project). The app
      # authenticates with a cert-auth managed role downloaded via the VM's
      # managed identity, so no DB credential is stored.
      add_foreign_key :postgres_resource_id, :postgres_resource, type: :uuid
    end
  end
end
