# frozen_string_literal: true

Sequel.migration do
  # Each statement commits on its own. Validating the check scans the table
  # without an exclusive lock. With a valid check, SET NOT NULL does not scan
  # it again, so its exclusive lock is brief. If a statement fails, running
  # the migration again repeats the ones before it harmlessly.
  no_transaction

  up do
    run "ALTER TABLE ipv4_address VALIDATE CONSTRAINT ipv4_address_assigned_not_null"
    run "ALTER TABLE ipv4_address ALTER COLUMN assigned SET NOT NULL"
    run "ALTER TABLE ipv4_address DROP CONSTRAINT IF EXISTS ipv4_address_assigned_not_null"
  end

  down do
    run "ALTER TABLE ipv4_address ALTER COLUMN assigned DROP NOT NULL"
  end
end
