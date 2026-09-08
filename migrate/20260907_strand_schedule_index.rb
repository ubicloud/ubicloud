# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :strand, [:schedule, :id, :lease], where: {exitval: nil}, name: :strand_schedule_id_lease_idx, concurrently: true
  end
end
