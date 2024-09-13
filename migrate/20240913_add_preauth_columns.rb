# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:payment_method) do
      add_column :preauth_amount, Integer, null: true
      add_column :preauth_intent_id, :text, collate: '"C"', null: true, unique: true
    end
  end
end
