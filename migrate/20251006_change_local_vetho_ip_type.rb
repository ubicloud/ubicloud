# frozen_string_literal: true

Sequel.migration do
  up do
    run "ALTER TABLE vm ALTER COLUMN local_vetho_ip TYPE cidr USING local_vetho_ip::cidr"
  end

  down do
    run "ALTER TABLE vm ALTER COLUMN local_vetho_ip TYPE text USING local_vetho_ip::text"
  end
end
