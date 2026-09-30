# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:oidc_provider) do
      add_column :groups_claim, String
    end
  end
end
