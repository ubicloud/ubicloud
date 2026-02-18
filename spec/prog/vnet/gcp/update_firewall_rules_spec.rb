# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::UpdateFirewallRules do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new }
  let(:vm) { instance_double(Vm, name: "testvm") }
  let(:ubicloud_project) { instance_double(Project, ubid: "pjtest1234567890abcdef12") }
  let(:vpc_name) { "ubicloud-proj-#{ubicloud_project.ubid}" }
  let(:firewalls_client) { instance_double(Google::Cloud::Compute::V1::Firewalls::Rest::Client) }
  let(:credential) {
    instance_double(LocationCredential,
      firewalls_client:,
      project_id: "test-gcp-project")
  }
  let(:location) { instance_double(Location, location_credential: credential) }

  before do
    nx.instance_variable_set(:@vm, vm)
    allow(vm).to receive_messages(location:, project: ubicloud_project, nics: [])
  end

  describe "#before_run" do
    it "pops if vm is to be destroyed" do
      expect(vm).to receive(:destroy_set?).and_return(true)
      expect { nx.before_run }.to exit({"msg" => "firewall rule is added"})
    end

    it "does not pop if vm is not to be destroyed" do
      expect(vm).to receive(:destroy_set?).and_return(false)
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    it "pops when there are no firewall rules" do
      expect(vm).to receive(:firewall_rules).and_return([])
      expect(firewalls_client).to receive(:list).twice.and_return([])

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "creates a GCE firewall rule for IPv4 rules" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        fw = args[:firewall_resource]
        expect(fw.name).to eq("ubicloud-fw-testvm")
        expect(fw.direction).to eq("INGRESS")
        expect(fw.network).to eq("projects/test-gcp-project/global/networks/#{vpc_name}")
        expect(fw.source_ranges).to eq(["0.0.0.0/0"])
        expect(fw.target_tags).to eq(["testvm"])
        expect(fw.allowed.size).to eq(1)
        expect(fw.allowed.first.I_p_protocol).to eq("tcp")
        expect(fw.allowed.first.ports).to eq(["5432"])
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "creates separate GCE rules for different CIDRs" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("10.0.0.0/24"),
          port_range: Sequel.pg_range(22..23), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!).twice

      created_names = []
      expect(firewalls_client).to receive(:insert).twice do |args|
        created_names << args[:firewall_resource].name
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
      expect(created_names).to contain_exactly("ubicloud-fw-testvm", "ubicloud-fw-testvm-1")
    end

    it "creates a GCE firewall rule for IPv6 rules" do
      rules = [
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("::/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert) do |args|
        fw = args[:firewall_resource]
        expect(fw.name).to eq("ubicloud-fw6-testvm")
        expect(fw.source_ranges).to eq(["::/0"])
        expect(fw.allowed.first.I_p_protocol).to eq("tcp")
        expect(fw.allowed.first.ports).to eq(["5432"])
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "creates separate GCE rules for IPv4 and IPv6" do
      rules = [
        instance_double(FirewallRule, ip6?: true, cidr: NetAddr::IPv6Net.parse("::/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!).twice

      created_rules = []
      expect(firewalls_client).to receive(:insert).twice do |args|
        fw = args[:firewall_resource]
        created_rules << {name: fw.name, source_ranges: fw.source_ranges.to_a}
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
      expect(created_rules).to contain_exactly(
        {name: "ubicloud-fw-testvm", source_ranges: ["0.0.0.0/0"]},
        {name: "ubicloud-fw6-testvm", source_ranges: ["::/0"]}
      )
    end

    it "updates an existing GCE firewall rule" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)

      existing = Google::Cloud::Compute::V1::Firewall.new(name: "ubicloud-fw-testvm")
      expect(firewalls_client).to receive(:list).and_return([existing])
      expect(firewalls_client).to receive(:list).and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:update).with(
        hash_including(project: "test-gcp-project", firewall: "ubicloud-fw-testvm")
      ).and_return(op)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "deletes stale GCE firewall rules" do
      expect(vm).to receive(:firewall_rules).and_return([])

      stale = Google::Cloud::Compute::V1::Firewall.new(name: "ubicloud-fw-testvm")
      expect(firewalls_client).to receive(:list).and_return([stale])
      expect(firewalls_client).to receive(:list).and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:delete).with(
        project: "test-gcp-project",
        firewall: "ubicloud-fw-testvm"
      ).and_return(op)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "handles NotFoundError when deleting stale rules" do
      expect(vm).to receive(:firewall_rules).and_return([])

      stale = Google::Cloud::Compute::V1::Firewall.new(name: "ubicloud-fw-testvm")
      expect(firewalls_client).to receive(:list).and_return([stale])
      expect(firewalls_client).to receive(:list).and_return([])

      expect(firewalls_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "handles list errors gracefully" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).and_raise(Google::Cloud::Error.new("list failed"))

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert).and_return(op)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "deletes stale IPv6 GCE firewall rules when IPv6 rules are removed" do
      expect(vm).to receive(:firewall_rules).and_return([])

      stale_v6 = Google::Cloud::Compute::V1::Firewall.new(name: "ubicloud-fw6-testvm")
      expect(firewalls_client).to receive(:list).and_return([])
      expect(firewalls_client).to receive(:list).and_return([stale_v6])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:delete).with(
        project: "test-gcp-project",
        firewall: "ubicloud-fw6-testvm"
      ).and_return(op)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "handles port ranges correctly" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(80..10000), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert) do |args|
        fw = args[:firewall_resource]
        expect(fw.allowed.first.ports).to eq(["80-9999"])
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "groups multiple ports from the same CIDR into one rule" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(22..23), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert) do |args|
        fw = args[:firewall_resource]
        expect(fw.name).to eq("ubicloud-fw-testvm")
        expect(fw.allowed.size).to eq(1)
        expect(fw.allowed.first.ports).to contain_exactly("5432", "22")
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "groups UDP and TCP separately" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp"),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(53..54), protocol: "udp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert) do |args|
        fw = args[:firewall_resource]
        expect(fw.allowed.size).to eq(2)
        protocols = fw.allowed.map(&:I_p_protocol)
        expect(protocols).to contain_exactly("tcp", "udp")
        op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "skips rules without port_range" do
      rules = [
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: nil),
        instance_double(FirewallRule, ip6?: false, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          port_range: Sequel.pg_range(5432..5433), protocol: "tcp")
      ]
      expect(vm).to receive(:firewall_rules).and_return(rules)
      expect(firewalls_client).to receive(:list).twice.and_return([])

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(firewalls_client).to receive(:insert).once.and_return(op)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end
  end
end
