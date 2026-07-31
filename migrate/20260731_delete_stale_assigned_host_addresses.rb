# frozen_string_literal: true

# create_addresses inserted an assigned_host_address row for every
# non-failover record it pulled, including routed blocks and IPv6 prefixes
# that belong to VMs rather than to the host. An assigned_host_address
# row must mean the host claims the address, so drop every row that is
# not the host's own sshable address. Nothing read the extra rows.
Sequel.migration do
  up do
    run <<~SQL
      DELETE FROM assigned_host_address AS aha
      USING sshable AS s
      WHERE s.id = aha.host_id AND host(aha.ip) != s.host
    SQL
  end
end
