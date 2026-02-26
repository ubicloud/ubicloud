# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "spec_helper"

RSpec.describe PrivateSubnet do
  subject(:private_subnet) {
    described_class.create(
      net6: NetAddr.parse_net("fd1b:9793:dcef:cd0a::/64"),
      net4: NetAddr.parse_net("10.9.39.0/26"),
      location_id: Location::HETZNER_FSN1_ID,
      state: "waiting",
      name: "ps",
      project_id: Project.create(name: "test").id
    )
  }

  it "disallows VM ubid format as name" do
    ps = described_class.new(name: described_class.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to eq ["cannot be exactly 26 numbers/lowercase characters starting with ps to avoid overlap with id format"]
  end

  it "allows inference endpoint ubid format as name" do
    ps = described_class.new(name: InferenceEndpoint.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to be_nil
  end

  describe "random ip generation" do
    it "returns random private ipv4" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(58).and_return(5)
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.9/32"
    end

    it "returns random private ipv6" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(32766).and_return(5)
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:c::/79"
    end

    context "when ip exists" do
      before do
        private_subnet.save_changes
        Nic.create(
          private_subnet_id: private_subnet.id,
          private_ipv4: "10.9.39.5/32",
          private_ipv6: "fd1b:9793:dcef:cd0a:c::/79",
          mac: "00:00:00:00:00:01",
          name: "existing-nic",
          state: "active"
        )
      end

      it "returns random private ipv4" do
        expect(SecureRandom).to receive(:random_number).with(58).and_return(1, 2)
        expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.6/32"
      end

      it "returns random private ipv6" do
        expect(SecureRandom).to receive(:random_number).with(32766).and_return(5, 6)
        expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:e::/79"
      end
    end
  end

  describe ".[]" do
    it "looks up by ubid object" do
      expect(described_class[UBID.parse(private_subnet.ubid)].id).to eq private_subnet.id
    end

    it "looks up by ubid string" do
      expect(described_class[private_subnet.ubid].id).to eq private_subnet.id
    end

    it "looks up by uuid string" do
      expect(described_class[private_subnet.id].id).to eq private_subnet.id
    end

    it "looks up by hash" do
      expect(described_class[id: private_subnet.id].id).to eq private_subnet.id
    end

    it "doesn't raise if given something that looks like a ubid but isn't" do
      expect(described_class["a" * 26]).to be_nil
    end
  end

  describe "#inspect" do
    it "includes ubid if id is available" do
      expect(private_subnet.inspect).to eq "#<PrivateSubnet[\"#{private_subnet.ubid}\"] @values={net6: \"fd1b:9793:dcef:cd0a::/64\", net4: \"10.9.39.0/26\", state: \"waiting\", name: \"ps\", last_rekey_at: \"#{private_subnet.last_rekey_at.strftime("%F %T")}\", project_id: \"#{private_subnet.project.ubid}\", location_id: \"10saktg1sprp3mxefj1m3kppq2\"}>"
    end
  end

  describe "uuid to name" do
    it "returns the name" do
      expect(described_class.ubid_to_name("psetv2ff83xj6h3prt2jwavh0q")).to eq "psetv2ff"
    end
  end

  describe "ui utility methods" do
    it "returns path" do
      expect(private_subnet.path).to eq "/location/eu-central-h1/private-subnet/ps"
    end
  end

  describe "display_state" do
    before { Strand.create_with_id(private_subnet, prog: "Vnet::Metal::SubnetNexus", label: "wait") }

    it "returns 'deleting' when destroy semaphore is set" do
      private_subnet.incr_destroy
      expect(private_subnet.display_state).to eq("deleting")
    end

    it "returns 'deleting' when destroying semaphore is set" do
      private_subnet.incr_destroying
      expect(private_subnet.display_state).to eq("deleting")
    end

    it "returns available when waiting" do
      expect(private_subnet.display_state).to eq "available"
    end

    it "returns state if not waiting" do
      private_subnet.state = "failed"
      expect(private_subnet.display_state).to eq "failed"
    end
  end

  describe "destroy" do
    it "destroys firewalls private subnets" do
      project_id = Project.create(name: "test").id
      ps = described_class.create(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "2001:db8::/64", net4: "10.0.0.0/24", project_id:)
      ps.add_firewall(project_id:, location_id: Location::HETZNER_FSN1_ID)
      expect(ps.firewalls_dataset.count).to eq 1
      ps.destroy
      expect(ps.firewalls_dataset.count).to eq 0
    end
  end

  describe ".create_tunnels" do
    let(:ps) {
      described_class.create(
        name: "tunnel-test-ps",
        location_id: Location::HETZNER_FSN1_ID,
        net6: "fd10:9b0b:6b4b:8fbb::/64",
        net4: "10.0.0.0/26",
        state: "waiting",
        project_id: Project.create(name: "tunnel-test-project").id
      )
    }
    let(:src_nic) {
      Nic.create(
        private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:01",
        name: "src-nic",
        state: "active"
      )
    }
    let(:dst_nic) {
      Nic.create(
        private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
        private_ipv4: "10.0.0.2",
        mac: "00:00:00:00:00:02",
        name: "dst-nic",
        state: "active"
      )
    }

    it "creates tunnels if doesn't exist" do
      ps.create_tunnels([src_nic, dst_nic], dst_nic)
      expect(IpsecTunnel[src_nic_id: src_nic.id, dst_nic_id: dst_nic.id]).not_to be_nil
      expect(IpsecTunnel[src_nic_id: dst_nic.id, dst_nic_id: src_nic.id]).not_to be_nil
    end

    it "skips existing tunnels" do
      IpsecTunnel.create(src_nic_id: src_nic.id, dst_nic_id: dst_nic.id)
      expect(IpsecTunnel.count).to eq 1

      ps.create_tunnels([src_nic, dst_nic], dst_nic)

      expect(IpsecTunnel.count).to eq 2
      expect(IpsecTunnel[src_nic_id: dst_nic.id, dst_nic_id: src_nic.id]).not_to be_nil
    end

    it "skips existing tunnels - 2" do
      IpsecTunnel.create(src_nic_id: dst_nic.id, dst_nic_id: src_nic.id)
      expect(IpsecTunnel.count).to eq 1

      ps.create_tunnels([src_nic, dst_nic], dst_nic)

      expect(IpsecTunnel.count).to eq 2
      expect(IpsecTunnel[src_nic_id: src_nic.id, dst_nic_id: dst_nic.id]).not_to be_nil
    end
  end

  describe "incr_destroy_if_only_used_internally" do
    let(:prj) { Project.create(name: "test-prj") }

    let(:ps) { Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps1", location_id: Location::HETZNER_FSN1_ID).subject }

    it "destroys associated firewalls in any project if name matches and firewall is not related to other subnets" do
      ubid = described_class.generate_ubid
      ps.firewalls.first.update(name: "#{ubid}-firewall")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.firewalls_dataset.all).to be_empty
    end

    it "does not destroy associated firewalls if name does match" do
      ps.incr_destroy_if_only_used_internally(
        ubid: described_class.generate_ubid,
        vm_ids: []
      )
      expect(ps.firewalls_dataset.count).to eq 1
    end

    it "does not destroy associated firewalls associated to other private subnets" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      fw.associate_with_private_subnet(ps2)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.firewalls_dataset.count).to eq 1
    end

    it "incr_destroys private subnet if name matches, and it does not have any firewalls or vms" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_order_map(:name)).to eq ["destroy", "update_firewall_rules"]
    end

    it "incr_destroys private subnet if name matches, and it does not have any firewalls or vms other the ones given in vm_ids" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: [vm.id]
      )
      expect(ps.semaphores_dataset.select_order_map(:name)).to eq ["destroy", "update_firewall_rules"]
    end

    it "does not incr_destroy private subnet if name does not match" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet2")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules"]
    end

    it "does not incr_destroy private subnet if firewalls remain" do
      ubid = described_class.generate_ubid
      ps.update(name: "#{ubid}-subnet")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq []
    end

    it "does not incr_destroy private subnet if it contains vms not listed in vm_ids" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules"]
    end

    it "incr_destroys private subnet if it only contains nics with nil vm_id" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject
      vm.nic.update(vm_id: nil)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules", "destroy"]
    end
  end

  describe "connected subnets related methods" do
    let(:prj) {
      Project.create(name: "test-prj")
    }

    let(:ps1) {
      Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps1", location_id: Location::HETZNER_FSN1_ID).subject
    }

    it ".connected_subnets" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      expect(ps1.connected_subnets).to eq []

      ps1.connect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id)).to eq [ps1.id]

      ps3 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps3", location_id: Location::HETZNER_FSN1_ID).subject
      ps2.connect_subnet(ps3)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id).sort).to eq [ps1.id, ps3.id].sort
      expect(ps3.connected_subnets.map(&:id)).to eq [ps2.id]

      ps1.disconnect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq []
      expect(ps2.connected_subnets.map(&:id).sort).to eq [ps3.id].sort
      expect(ps3.connected_subnets.map(&:id)).to eq [ps2.id]
    end

    it ".all_nics" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject

      ps1_nic = Prog::Vnet::NicNexus.assemble(ps1.id, name: "test-ps1-nic1").subject
      ps2_nic = Prog::Vnet::NicNexus.assemble(ps2.id, name: "test-ps2-nic1").subject

      expect(ps1.all_nics.map(&:id)).to eq [ps1_nic.id]

      expect(ps1).to receive(:create_tunnels).with([ps2_nic], ps1_nic).and_call_original
      ps1.connect_subnet(ps2)

      expect(ps1.all_nics.map(&:id).sort).to eq [ps1_nic.id, ps2_nic.id].sort

      ps1.disconnect_subnet(ps2)

      expect(ps1.all_nics.map(&:id)).to eq [ps1_nic.id]
    end

    it "disconnect_subnet does not destroy in subnet tunnels" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      ps1_nic = Prog::Vnet::NicNexus.assemble(ps1.id, name: "test-ps1-nic1").subject
      ps1_nic2 = Prog::Vnet::NicNexus.assemble(ps1.id, name: "test-ps1-nic2").subject
      ps1.create_tunnels([ps1_nic], ps1_nic2)

      ps2_nic = Prog::Vnet::NicNexus.assemble(ps2.id, name: "test-ps2-nic1").subject
      ps1.connect_subnet(ps2)
      expect(ps1.find_all_connected_nics.map(&:id).sort).to eq [ps1_nic.id, ps1_nic2.id, ps2_nic.id].sort
      expect(IpsecTunnel.count).to eq 6

      ps1.disconnect_subnet(ps2)
      expect(ps1.find_all_connected_nics.map(&:id).sort).to eq [ps1_nic.id, ps1_nic2.id].sort

      tunnels = ps1_nic.src_ipsec_tunnels + ps1_nic.dst_ipsec_tunnels
      expect(IpsecTunnel.all.map(&:id).sort).to eq(tunnels.map(&:id).sort)
      expect(IpsecTunnel.count).to eq 2
    end
  end

  describe "AWS connect/disconnect subnet" do
    let(:prj) { Project.create(name: "test-aws-prj") }

    let(:location) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id,
        display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      LocationCredential.create_with_id(loc, access_key: "test-access-key", secret_key: "test-secret-key")
      LocationAwsAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
      loc
    }

    let(:ps1) {
      described_class.create(name: "aws-ps1", location_id: location.id,
        net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26",
        state: "waiting", project_id: prj.id)
    }

    let(:ps2) {
      described_class.create(name: "aws-ps2", location_id: location.id,
        net6: "fd10:9b0b:6b4b:8fbc::/64", net4: "10.0.1.0/26",
        state: "waiting", project_id: prj.id)
    }

    it "creates and destroys ConnectedSubnet records" do
      ps1.connect_subnet(ps2)
      expect(ConnectedSubnet.where(
        subnet_id_1: [ps1.id, ps2.id].min,
        subnet_id_2: [ps1.id, ps2.id].max
      ).count).to eq 1

      ps1.disconnect_subnet(ps2)
      expect(ConnectedSubnet.where(
        subnet_id_1: [ps1.id, ps2.id].min,
        subnet_id_2: [ps1.id, ps2.id].max
      ).count).to eq 0
    end
  end

  describe "GCP cross-subnet firewall rules" do
    let(:prj) { Project.create(name: "test-gcp-prj") }

    let(:location) {
      Location.create(name: "gcp-us-central1", provider: "gcp", project_id: prj.id,
        display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
    }

    let(:credential) {
      LocationCredential.create_with_id(location,
        project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
        credentials_json: "{}")
    }

    let(:ps1) {
      credential
      described_class.create(name: "gcp-ps1", location_id: location.id,
        net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26",
        state: "waiting", project_id: prj.id)
    }

    let(:ps2) {
      credential
      described_class.create(name: "gcp-ps2", location_id: location.id,
        net6: "fd10:9b0b:6b4b:8fbc::/64", net4: "10.0.1.0/26",
        state: "waiting", project_id: prj.id)
    }

    let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }

    before do
      allow(credential).to receive_messages(
        network_firewall_policies_client: nfp_client
      )
      ps1 # force creation so we can stub on the instance's location
      allow(ps1.location).to receive(:location_credential).and_return(credential)
    end

    describe "connect_subnet" do
      it "creates ConnectedSubnet record and 4 policy rules" do
        expect(nfp_client).to receive(:get_rule).exactly(4).times
          .and_raise(Google::Cloud::NotFoundError.new("not found"))
        expect(nfp_client).to receive(:add_rule).exactly(4).times

        ps1.connect_subnet(ps2)

        expect(ConnectedSubnet.where(
          subnet_id_1: [ps1.id, ps2.id].min,
          subnet_id_2: [ps1.id, ps2.id].max
        ).count).to eq 1
      end

      it "skips add_rule when rule already exists" do
        expect(nfp_client).to receive(:get_rule).exactly(4).times
          .and_return(Google::Cloud::Compute::V1::FirewallPolicyRule.new)
        expect(nfp_client).not_to receive(:add_rule)

        ps1.connect_subnet(ps2)
      end
    end

    describe "disconnect_subnet" do
      before do
        ConnectedSubnet.create(
          subnet_id_1: [ps1.id, ps2.id].min,
          subnet_id_2: [ps1.id, ps2.id].max
        )
      end

      it "destroys ConnectedSubnet record and removes 4 policy rules" do
        expect(nfp_client).to receive(:remove_rule).exactly(4).times

        ps1.disconnect_subnet(ps2)

        expect(ConnectedSubnet.where(
          subnet_id_1: [ps1.id, ps2.id].min,
          subnet_id_2: [ps1.id, ps2.id].max
        ).count).to eq 0
      end

      it "handles NotFoundError gracefully on remove" do
        expect(nfp_client).to receive(:remove_rule).exactly(4).times
          .and_raise(Google::Cloud::NotFoundError.new("not found"))

        ps1.disconnect_subnet(ps2)

        expect(ConnectedSubnet.where(
          subnet_id_1: [ps1.id, ps2.id].min,
          subnet_id_2: [ps1.id, ps2.id].max
        ).count).to eq 0
      end
    end

    describe "cross_subnet_rule_priority" do
      it "generates deterministic priority" do
        priority = ps1.send(:cross_subnet_rule_priority, ps1, ps2, "egress")
        expect(priority).to be_between(2000, 9999)
        expect(ps1.send(:cross_subnet_rule_priority, ps1, ps2, "egress")).to eq(priority)
      end
    end

    describe "create_cross_subnet_rules firewall attributes" do
      it "creates egress rules with src and dest IP ranges, and ingress rules with src and dest IP ranges" do
        created_rules = []
        expect(nfp_client).to receive(:get_rule).exactly(4).times
          .and_raise(Google::Cloud::NotFoundError.new("not found"))
        expect(nfp_client).to receive(:add_rule).exactly(4).times do |args|
          rule = args[:firewall_policy_rule_resource]
          created_rules << {
            direction: rule.direction,
            src_ip_ranges: rule.match.src_ip_ranges.to_a,
            dest_ip_ranges: rule.match.dest_ip_ranges.to_a
          }
        end

        ps1.send(:create_cross_subnet_rules, ps2)

        egress_rules = created_rules.select { |r| r[:direction] == "EGRESS" }
        ingress_rules = created_rules.select { |r| r[:direction] == "INGRESS" }

        expect(egress_rules.length).to eq 2
        expect(ingress_rules.length).to eq 2

        # Egress rules have src (local subnet) and dest (remote subnet) IP ranges
        egress_rules.each do |r|
          expect(r[:src_ip_ranges]).not_to be_empty
          expect(r[:dest_ip_ranges]).not_to be_empty
        end

        # Ingress rules have src (remote subnet) and dest (local subnet) IP ranges
        ingress_rules.each do |r|
          expect(r[:src_ip_ranges]).not_to be_empty
          expect(r[:dest_ip_ranges]).not_to be_empty
        end
      end
    end
  end
end
