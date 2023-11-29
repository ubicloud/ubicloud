# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:account_webauthn_keys) do
      add_column :name, :text, collate: '"C"'
    end
  end
end
