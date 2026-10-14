# frozen_string_literal: true

# A NOT VALID check is enforced for new rows only, so adding it scans
# nothing. It cannot come before the triggers, which give new rows a value.
Sequel.migration do
  up do
    run "ALTER TABLE ipv4_address ADD CONSTRAINT ipv4_address_assigned_not_null CHECK (assigned IS NOT NULL) NOT VALID"
  end

  down do
    run "ALTER TABLE ipv4_address DROP CONSTRAINT IF EXISTS ipv4_address_assigned_not_null"
  end
end
