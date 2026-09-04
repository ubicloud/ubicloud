# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:account_source) do
      foreign_key :account_id, :accounts, type: :uuid, on_delete: :cascade
      String :source, size: 32, collate: '"C"', null: false
      String :detail, size: 36, collate: '"C"'
      primary_key [:account_id, :source]
      constraint(:nonempty_source) { char_length(:source) >= 1 }
    end
  end
end
