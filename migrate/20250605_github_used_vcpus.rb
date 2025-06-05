# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:github_installation) do
      add_column :used_vcpus_x64, :Integer, null: false, default: 0
      add_column :used_vcpus_arm64, :Integer, null: false, default: 0
    end
  end
end
