# frozen_string_literal: true

class Vm < Sequel::Model
  module Gcp
    private

    def gcp_ip6
      ephemeral_net6&.nth(0)
    end

    def gcp_update_firewall_rules_prog
      Prog::Vnet::Gcp::UpdateFirewallRules
    end

    def gcp_validate_firewall_cap(firewall)
      Firewall.validate_gcp_firewall_cap!(self, additional_firewall_ids: [firewall.id])
    end
  end
end
