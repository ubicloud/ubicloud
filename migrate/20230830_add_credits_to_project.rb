# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :credit, :numeric, null: false, default: 0
      add_constraint(:min_credit_amount) { credit >= 0 }
      add_column :discount, :Integer, null: false, default: 0
      add_constraint(:max_discount_amount) { discount <= 100 }
    end
  end
end
