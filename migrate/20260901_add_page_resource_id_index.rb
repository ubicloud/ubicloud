# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :page, :resource_id, where: {resolved_at: nil}, concurrently: true
  end
end
