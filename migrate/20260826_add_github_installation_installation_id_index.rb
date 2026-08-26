# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :github_installation, [:installation_id], unique: true, concurrently: true
  end
end
