# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:firewall_rule) do
      drop_constraint :firewall_rule_cidr_port_range_firewall_id_key
      add_column :protocol, :text, null: false, default: "tcp"
      add_unique_constraint [:cidr, :port_range, :firewall_id, :protocol], name: :firewall_rule_unique
      add_constraint :valid_protocol, protocol: %w[tcp udp]
    end
  end

  down do
    alter_table(:firewall_rule) do
      drop_column :protocol, :text, null: false, default: "tcp"
      drop_constraint :firewall_rule_unique
      drop_constraint :valid_protocol
      add_unique_constraint [:cidr, :port_range, :firewall_id], name: :firewall_rule_cidr_port_range_firewall_id_key
    end
  end
end
