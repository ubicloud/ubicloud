# frozen_string_literal: true

class Vm < Sequel::Model
  module Aws
    private

    def aws_ip6
      ephemeral_net6&.nth(0)
    end

    def aws_update_firewall_rules_prog
      Prog::Vnet::Aws::UpdateFirewallRules
    end
  end
end
