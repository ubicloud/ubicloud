# frozen_string_literal: true

# Adds ipv4_address.assigned in stages, so that no stage holds a lock that
# blocks allocations for long. The column starts nullable and without a
# default: existing rows are NULL until the backfill, which only touches
# rows that are still NULL.
Sequel.migration do
  change do
    alter_table(:ipv4_address) do
      add_column :assigned, :boolean
    end
  end
end
