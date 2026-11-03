# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:invoice) do
      add_column :kind, :text, null: false, default: "usage"
      add_constraint(:invoice_kind_check, kind: %w[usage prepaid_credit])
    end
  end
end
