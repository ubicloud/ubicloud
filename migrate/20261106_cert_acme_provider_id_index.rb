# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:cert) do
      add_index :acme_provider_id, where: Sequel.~(acme_provider_id: nil), concurrently: true
    end
  end
end
