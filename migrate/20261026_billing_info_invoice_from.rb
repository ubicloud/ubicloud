# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:billing_info) do
      add_column :invoice_from, :text, collate: '"C"'
      add_constraint :valid_invoice_from, invoice_from: %w[inc bv]
    end
  end
end
