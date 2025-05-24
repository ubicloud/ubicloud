# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Firewall do
  let(:project_id) { Project.create(name: "test").id }

  let(:fw) {
    described_class.create_with_id(name: "test-fw", description: "test fw desc", location_id: Location::HETZNER_FSN1_ID, project_id:)
  }

  let(:ps) {
    PrivateSubnet.create_with_id(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "2001:db8::/64", net4: "10.0.0.0/24", project_id:)
  }

  it "inserts firewall rules" do
    fw.insert_firewall_rule("10.0.0.16/28", Sequel.pg_range(80..5432))
    expect(fw.firewall_rules.count).to eq(1)
    expect(fw.firewall_rules.first.cidr.to_s).to eq("10.0.0.16/28")
    pr = fw.firewall_rules.first.port_range
    expect(pr.begin).to eq(80)
    expect(pr.end).to eq(5433)
  end

  it "increments VMs update_firewall_rules if there is a VM" do
    private_subnet = instance_double(PrivateSubnet)
    expect(fw).to receive(:private_subnets).and_return([private_subnet])
    expect(private_subnet).to receive(:incr_update_firewall_rules)
    fw.insert_firewall_rule("0.0.0.0/0", nil)
  end

  it "bulk sets firewall rules" do
    fw.insert_firewall_rule("10.0.0.16/28", Sequel.pg_range(80..5432))
    fw.insert_firewall_rule("0.0.0.0/32", Sequel.pg_range(5432..5432))
    fw.replace_firewall_rules([{cidr: "0.0.0.0/32", port_range: Sequel.pg_range(5432..5432)}])
    expect(fw.reload.firewall_rules.count).to eq(1)
    expect(fw.reload.firewall_rules.first.cidr.to_s).to eq("0.0.0.0/32")
  end

  it "associates with a private subnet" do
    expect(ps).to receive(:incr_update_firewall_rules)
    fw.associate_with_private_subnet(ps)

    expect(fw.private_subnets.count).to eq(1)
    expect(fw.private_subnets.first.id).to eq(ps.id)
  end

  it "disassociates from a private subnet" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect(fw.private_subnets.count).to eq(1)

    expect(ps).to receive(:incr_update_firewall_rules)
    fw.disassociate_from_private_subnet(ps)
    expect(fw.reload.private_subnets.count).to eq(0)
    expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(0)
  end

  it "disassociates from a private subnet without applying firewalls" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect(fw.private_subnets.count).to eq(1)

    expect(ps).not_to receive(:incr_update_firewall_rules)
    fw.disassociate_from_private_subnet(ps, apply_firewalls: false)
    expect(fw.reload.private_subnets.count).to eq(0)
    expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(0)
  end

  it "destroys firewall" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect(fw.reload.private_subnets.count).to eq(1)
    expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(1)
    fw.destroy
    expect(FirewallsPrivateSubnets.where(firewall_id: fw.id).count).to eq(0)
    expect(described_class[fw.id]).to be_nil
  end

  it "removes referencing access control entries and object tag memberships" do
    account = Account.create_with_id(email: "test@example.com")
    project = account.create_project_with_default_policy("project-1", default_policy: false)
    tag = ObjectTag.create_with_id(project_id: project.id, name: "t")
    tag.add_member(fw.id)
    fw.update(project_id: project.id)
    ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: account.id, object_id: fw.id)

    fw.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end
end
