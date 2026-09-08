# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :strand, :parent_id, where: Sequel.~(parent_id: nil), name: :strand_parent_id_idx, concurrently: true
  end
end
