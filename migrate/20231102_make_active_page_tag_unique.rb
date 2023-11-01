# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:page) do
      drop_constraint :page_tag_key, type: :unique
      add_index :tag, unique: true, where: {resolved_at: nil}, concurrently: true
    end
  end

  down do
    alter_table(:page) do
      drop_index [:tag], concurrently: true
      add_unique_constraint :tag
    end
  end
end
