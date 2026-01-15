# frozen_string_literal: true

class Vm < Sequel::Model
  module Metal
    private

    def metal_ip6
      ephemeral_net6&.nth(2)
    end

    def metal_update_firewall_rules_prog
      Prog::Vnet::Metal::UpdateFirewallRules
    end
  end
end
