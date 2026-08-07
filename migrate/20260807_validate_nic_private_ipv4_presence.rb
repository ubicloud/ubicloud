# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    run "ALTER TABLE nic VALIDATE CONSTRAINT nic_private_ipv4_presence_check"
  end

  down do
    # Nothing to do; the constraint remains valid.
  end
end
