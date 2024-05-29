# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_repository) do
      add_column :default_branch, :text, collate: '"C"'
    end
  end
end
