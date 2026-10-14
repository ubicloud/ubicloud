# frozen_string_literal: true

Sequel.migration do
  # Each subnet's update commits on its own, so row locks are held only for
  # one subnet at a time.
  no_transaction

  up do
    # The triggers are in place, so every row that is still NULL was written
    # before them. Keep "assigned IS NULL" in each update: when an assignment
    # commits after an update's snapshot, PostgreSQL tests the row's latest
    # version against it again, and skips the row the trigger already set.
    self[:ipv4_address].where(assigned: nil).distinct.select_map(:cidr).each do |cidr|
      self[:ipv4_address]
        .where(cidr:, assigned: nil)
        .update(assigned: self[:assigned_vm_address].where(ip: Sequel[:ipv4_address][:ip]).exists)
    end
  end

  # The column is dropped when the migration that adds it is rolled back.
  down do
  end
end
