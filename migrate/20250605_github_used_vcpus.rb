# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :used_vcpus, :Integer, null: false, default: 0
    end
  end
end
