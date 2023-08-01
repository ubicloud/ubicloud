# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:billing_info) do
      column :id, :uuid, primary_key: true, default: nil
      column :stripe_id, :text, collate: '"C"', null: false, unique: true
    end

    create_table(:payment_method) do
      column :id, :uuid, primary_key: true, default: nil
      column :stripe_id, :text, collate: '"C"', null: false, unique: true
      column :order, Integer
      foreign_key :billing_info_id, :billing_info, type: :uuid
    end

    alter_table(:project) do
      add_foreign_key :billing_info_id, :billing_info, type: :uuid, null: true
    end
  end
end
