# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:oidc_provider) do
      add_column :pkce_supported, :boolean, default: false, null: false
    end
  end
end
