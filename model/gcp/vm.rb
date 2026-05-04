# frozen_string_literal: true

class Vm < Sequel::Model
  module Gcp
    # GCP VMs (Compute instances) have a hard limit of 10 secure tag
    # bindings (see Prog::Vnet::Gcp::UpdateFirewallRules::GCP_MAX_TAGS_PER_VM).
    # One slot is always consumed by the subnet "active" tag, which leaves
    # 9 for per-firewall tags.
    GCP_MAX_FIREWALLS_PER_VM = 9

    private

    def gcp_ip6
      ephemeral_net6&.nth(0)
    end

    def gcp_update_firewall_rules_prog
      Prog::Vnet::Gcp::UpdateFirewallRules
    end

    def gcp_validate_firewall_cap(firewall)
      enforce_firewall_cap(additional_firewall_ids: [firewall.id])
    end

    def gcp_validate_subnet_firewall_cap(subnet)
      enforce_firewall_cap(additional_firewall_ids: subnet.firewalls_dataset.select_map(:id))
    end

    def enforce_firewall_cap(additional_firewall_ids:)
      firewall_ids = (firewalls.map(&:id) + additional_firewall_ids).to_set
      if firewall_ids.size > GCP_MAX_FIREWALLS_PER_VM
        fail Validation::ValidationFailed.new(firewall: "GCP VMs cannot be attached to more than #{GCP_MAX_FIREWALLS_PER_VM} firewalls")
      end
    end
  end
end
