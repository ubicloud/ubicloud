# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :provider, String, collate: '"C"'
    end
  end
end
