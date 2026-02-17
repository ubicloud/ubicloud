# frozen_string_literal: true

class Prog::Vnet::Gcp::UpdateFirewallRules < Prog::Base
  subject_is :vm

  def before_run
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    pop "firewall rule is added"
  end
end
