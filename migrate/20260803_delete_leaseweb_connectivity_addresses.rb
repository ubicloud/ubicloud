# frozen_string_literal: true

# create_addresses recorded the gatewayed IPv6 prefixes leaseweb hands out
# for host connectivity as Address rows, presenting them in assigned_subnets
# as if VMs could draw from them. Nothing allocates from them; drop the rows.
Sequel.migration do
  up do
    run <<~SQL
      DELETE FROM address AS a
      USING host_provider AS hp
      WHERE hp.id = a.routed_to_host_id
        AND hp.provider_name LIKE 'leaseweb%'
        AND family(a.cidr) = 6
        AND masklen(a.cidr) = 112
    SQL
  end
end
