# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: ubicloud_firewall_rule (generated)" do
  it "creates via collection POST, adopts the server-assigned id, reads and deletes by it" do
    runner = tf_runner("firewall_rule.tf.erb")

    create_gate = tf_gate(method: "POST", path: %r{/firewall/rule-host/firewall-rule\z})
    apply = tf_async { runner.apply }
    create_gate.wait_for_arrival
    fw = Firewall.first(name: "rule-host")
    # Dataset read, not association: the barrier must observe the
    # database, never a cached collection.
    expect(fw.firewall_rules_dataset.all).to be_empty
    create_gate.release
    apply.value

    rule = fw.firewall_rules_dataset.first
    attrs = runner.state_resources.find { it["address"] == "ubicloud_firewall_rule.r" }["values"]
    expect(attrs["id"]).to eq rule.ubid
    expect(attrs.values_at("cidr", "port_range")).to eq ["10.0.0.0/24", "5432"]
    expect(rule.cidr.to_s).to eq "10.0.0.0/24"

    delete_gate = tf_gate(method: "DELETE", path: %r{/firewall-rule/#{rule.ubid}\z})
    destroy = tf_async { runner.run!("destroy", "-auto-approve", "-no-color") }
    delete_gate.wait_for_arrival.release
    destroy.value
    expect(FirewallRule.where(firewall_id: fw.id).all).to be_empty
    expect(Firewall[fw.id]).to be_nil
  end
end
