# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:applied_tag) do
      drop_index [:access_tag_id, :tagged_id], concurrently: true
      add_primary_key [:access_tag_id, :tagged_id]
    end
  end

  down do
    alter_table(:applied_tag) do
      drop_index [:access_tag_id, :tagged_id], concurrently: true
      add_unique_constraint [:access_tag_id, :tagged_id]
    end
  end
end
