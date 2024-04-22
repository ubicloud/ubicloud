# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:payment_method) do
      add_column :card_fingerprint, :text, null: true
      add_column :fraud, :boolean, default: false, null: false
    end
  end
end
