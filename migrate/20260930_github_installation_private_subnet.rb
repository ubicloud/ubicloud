# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_installation_private_subnet) do
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, primary_key: true, on_delete: :cascade
      foreign_key :github_installation_id, :github_installation, type: :uuid, null: false
      index :github_installation_id
    end
  end
end
