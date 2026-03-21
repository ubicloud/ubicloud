# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :billing_record, :resource_tags, type: :gin, concurrently: true
  end
end
