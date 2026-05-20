# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:firewall_rule) do
      # UBID.to_base32_n("fr") => 504
      set_column_default :id, Sequel.function(:gen_random_ubid_uuid, 504)
    end

    ds = from(:firewall_rule)
    port_range = Sequel.pg_range(0...65536)
    ds.insert([:cidr, :port_range, :firewall_id, :description, :protocol],
      ds.where(port_range:, protocol: "tcp")
        .exclude(firewall_id: ds.where(port_range:, protocol: "udp").select(:firewall_id))
        .select(:cidr, :port_range, :firewall_id, :description, "udp"))
  end

  down do
    alter_table(:firewall_rule) do
      set_column_default :id, nil
    end
  end
end
