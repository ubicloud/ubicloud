# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:oidc_provider) do
      add_column :group_prefix, String
    end
  end
end
