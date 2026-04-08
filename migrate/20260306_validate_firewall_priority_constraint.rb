# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    run "ALTER TABLE private_subnet VALIDATE CONSTRAINT private_subnet_firewall_priority_check"
  end

  down do
    # Nothing to do; the constraint remains valid.
  end
end
