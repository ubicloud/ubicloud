# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:firewall_rule) do
      add_column :port_range, :int4range, null: true, default: Sequel.pg_range(0..65535)
    end
    run "ALTER TABLE firewall_rule ADD CONSTRAINT port_range_min_max CHECK (lower(port_range) >= 0 AND upper(port_range) <= 65536)"
  end

  down do
    alter_table(:firewall_rule) do
      drop_column :port_range
    end
  end
end
