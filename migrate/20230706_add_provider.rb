# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm) do
      add_column :provider, :text, collate: '"C"'
    end

    alter_table(:vm_host) do
      add_column :provider, :text, collate: '"C"'
    end

    alter_table(:project) do
      add_column :default_provider, :text, collate: '"C"'
    end
  end
end
