# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    run "ALTER TABLE private_subnet VALIDATE CONSTRAINT private_subnet_nic_ipv4_prefix_len_check"
  end

  down do
    # Nothing to do; the constraint remains valid.
  end
end
