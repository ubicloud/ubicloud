# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_repository) do
      add_column :use_temporary_access_token, :boolean, default: false
      add_column :session_token, :text, collate: '"C"'
      add_column :last_token_refreshed_at, :timestamptz
    end
  end
end
