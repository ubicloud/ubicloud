# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateSubnet do
  subject(:private_subnet) {
    described_class.create(
      net6: NetAddr.parse_net("fd1b:9793:dcef:cd0a::/64"),
      net4: NetAddr.parse_net("10.9.39.0/26"),
      location_id: Location::HETZNER_FSN1_ID,
      state: "waiting",
      name: "ps",
      project_id: Project.create(name: "test").id,
    )
  }

  it "disallows VM ubid format as name" do
    ps = described_class.new(name: described_class.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to eq ["cannot be exactly 26 numbers/lowercase characters starting with ps to avoid overlap with id format"]
  end

  describe "#apply_firewalls" do
    it "fires the subnet-level update_firewall_rules semaphore on AWS" do
      prj = Project.create(name: "aws-fw-prj")
      loc = Location.create(name: "us-west-2afw", provider: "aws", project_id: prj.id,
        display_name: "aws-us-west-2afw", ui_name: "AWS US West 2 AFW", visible: true)
      LocationCredentialAws.create_with_id(loc, access_key: "k", secret_key: "s")
      ps = described_class.create(name: "aws-fw-ps", location_id: loc.id,
        net6: "fd1b:9793:dcef:cd0b::/64", net4: "10.9.40.0/26",
        state: "waiting", project_id: prj.id)
      Strand.create(prog: "Vnet::SubnetNexus", label: "wait", id: ps.id)
      expect { ps.apply_firewalls }.to change { ps.reload.update_firewall_rules_set? }.from(false).to(true)
    end
  end

  it "allows inference endpoint ubid format as name" do
    ps = described_class.new(name: InferenceEndpoint.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to be_nil
  end

  describe "random ip generation" do
    it "returns random private ipv4 on metal (skips first 4 + last 1, same as AWS)" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(59).and_return(5)
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.9/32"
    end

    it "returns random private ipv4 on aws (skips first 4 + last 1)" do
      prj = Project.create(name: "aws-rand-prj")
      loc = Location.create(name: "us-west-2r", provider: "aws", project_id: prj.id,
        display_name: "aws-us-west-2r", ui_name: "AWS US West 2R", visible: true)
      LocationCredentialAws.create_with_id(loc, access_key: "k", secret_key: "s")
      ps = described_class.create(name: "aws-rand-ps", location_id: loc.id,
        net6: "fd1b:9793:dcef:cd0a::/64", net4: "10.9.39.0/26",
        state: "waiting", project_id: prj.id)
      expect(SecureRandom).to receive(:random_number).with(59).and_return(5)
      expect(ps.random_private_ipv4.to_s).to eq "10.9.39.9/32"
    end

    it "skips the sub-blocks containing the reserved edge addresses for bigger parent subnets" do
      prj = Project.create(name: "big-net-prj")
      ps = described_class.create(name: "big-ps", location_id: Location::HETZNER_FSN1_ID,
        net6: "fd1b:9793:dcef:cd0a::/64", net4: "10.9.0.0/16",
        state: "waiting", project_id: prj.id)
      (1..254).each do |i|
        Nic.create(private_subnet_id: ps.id, private_ipv4: "10.9.#{i}.0/24",
          private_ipv6: "fd1b:9793:dcef:cd0a:#{(i * 2).to_s(16)}::/79",
          mac: format("00:00:00:00:%02x:%02x", i / 256, i % 256),
          name: "nic-#{i}", state: "active")
      end
      # Only the reserved first and last /24 remain free; the allocator
      # must exhaust its draws rather than ever select one of them.
      expect { ps.random_private_ipv4 }.to raise_error(RuntimeError, "Could not find random IPv4 after 1000 iterations")
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
          state: "active",
        )
      end

      it "returns random private ipv4" do
        expect(SecureRandom).to receive(:random_number).with(59).and_return(1, 5)
        expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.9/32"
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
      expect(private_subnet.inspect).to eq "#<PrivateSubnet[\"#{private_subnet.ubid}\"] @values={net6: \"fd1b:9793:dcef:cd0a::/64\", net4: \"10.9.39.0/26\", state: \"waiting\", name: \"ps\", last_rekey_at: \"#{private_subnet.last_rekey_at.strftime("%F %T")}\", project_id: \"#{private_subnet.project.ubid}\", location_id: \"10saktg1sprp3mxefj1m3kppq2\", firewall_priority: nil}>"
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
        project_id: Project.create(name: "tunnel-test-project").id,
      )
    }
    let(:src_nic) {
      Nic.create(
        private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.1",
        mac: "00:00:00:00:00:01",
        name: "src-nic",
        state: "active",
      )
    }
    let(:dst_nic) {
      Nic.create(
        private_subnet_id: ps.id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
        private_ipv4: "10.0.0.2",
        mac: "00:00:00:00:00:02",
        name: "dst-nic",
        state: "active",
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
        vm_ids: [],
      )
      expect(ps.firewalls_dataset.all).to be_empty
    end

    it "does not destroy associated firewalls if name does match" do
      ps.incr_destroy_if_only_used_internally(
        ubid: described_class.generate_ubid,
        vm_ids: [],
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
        vm_ids: [],
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
        vm_ids: [],
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
        vm_ids: [vm.id],
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
        vm_ids: [],
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules"]
    end

    it "does not incr_destroy private subnet if firewalls remain" do
      ubid = described_class.generate_ubid
      ps.update(name: "#{ubid}-subnet")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: [],
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
        vm_ids: [],
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules"]
    end

    it "incr_destroys private subnet if it only contains nics with nil vm_id" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject
      vm.user_nic.update(vm_id: nil)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: [],
      )
      expect(ps.semaphores_dataset.order(:name).select_map(:name)).to eq ["destroy", "update_firewall_rules"]
    end

    it "incr_destroys private subnet if remaining nics belong to vms marked for destroy" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject
      vm.incr_destroy

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: [],
      )
      expect(ps.semaphores_dataset.select_order_map(:name)).to eq ["destroy", "update_firewall_rules"]
    end

    it "incr_destroys private subnet if remaining nics belong to vms marked as destroying" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject
      vm.incr_destroying

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: [],
      )
      expect(ps.semaphores_dataset.select_order_map(:name)).to eq ["destroy", "update_firewall_rules"]
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

    it "connect_subnet signals refresh_keys on both sides" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      ps1.connect_subnet(ps2)
      expect(ps1.refresh_keys_set?).to be true
      expect(ps2.refresh_keys_set?).to be true
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

  describe "#connected_leader_id" do
    # The method returns the smallest id among all subnets transitively
    # connected to the receiver (itself included), via the connected_subnet
    # edge table, using a recursive CTE. The v2 rekey coordinator relies on
    # this to pick a single coordinating subnet per mesh: correctness means
    # every member of a connected component must independently agree on the
    # same leader, and that leader must be the true minimum id.
    #
    # Ordering is by raw uuid bytes, which is not controllable through the
    # random ubids assemble generates. So these tests inject explicit,
    # hand-ordered uuids and assert against them, rather than asserting on
    # whatever random ids happened to be produced. That keeps them
    # deterministic and makes them a real guard: a refactor that dropped the
    # ORDER BY or the cycle exclusion would fail here instead of passing by
    # luck on a particular id draw. Edges are created only through the
    # `edge` helper, which sorts the pair so subnet_id_1 < subnet_id_2 holds
    # by construction (the connected_subnet unique_subnet_pair check forbids
    # self-edges and reversed pairs, and the unique index forbids dupes, so
    # those states are intentionally not exercised: they cannot occur).
    let(:leader_project) { Project.create(name: "test-leader") }

    # Deterministic, strictly increasing uuids: u(1) < u(2) < ... by the
    # byte ordering Postgres uses, so the expected leader of any subset is
    # the one built with the smallest argument.
    def u(n)
      format("00000000-0000-0000-0000-%012d", n)
    end

    # Metal subnet with an injected id, built through create_with_id (not
    # assemble) to skip firewall/tunnel machinery irrelevant to leader
    # selection, while landing in a metal location so Metal dispatch is live.
    def subnet(n, name: "psleader#{n}")
      PrivateSubnet.create_with_id(
        u(n),
        name:,
        location_id: Location::HETZNER_FSN1_ID,
        net6: NetAddr.parse_net("fd1b:9793:dcef:#{format("%04x", n)}::/64"),
        net4: NetAddr.parse_net("10.#{n}.0.0/16"),
        state: "waiting",
        project_id: leader_project.id,
      )
    end

    # Wire a connected_subnet edge, pair sorted to satisfy the
    # subnet_id_1 < subnet_id_2 check.
    def edge(a, b)
      lo, hi = [a.id, b.id].sort
      ConnectedSubnet.create(subnet_id_1: lo, subnet_id_2: hi)
    end

    # Every member of a component must agree, and the answer must be the
    # expected subnet. This is the invariant the coordinator depends on, so
    # it is checked for every topology, not spot-checked on one node.
    def expect_unanimous_leader(members, expected)
      leaders = members.map { |ps| ps.reload.connected_leader_id }
      expect(leaders.uniq).to eq([expected.id]),
        "expected all of #{members.map(&:name)} to agree on leader " \
        "#{expected.name} (#{expected.id}), got #{leaders.uniq}"
    end

    it "returns own id for a standalone subnet (no edges)" do
      ps = subnet(1)
      expect(ps.connected_leader_id).to eq(ps.id)
    end

    it "returns the smaller id for a simple pair, both agreeing" do
      lo = subnet(1)
      hi = subnet(2)
      edge(lo, hi)
      expect_unanimous_leader([lo, hi], lo)
    end

    it "ignores subnets in other, unconnected components" do
      # Two separate pairs; each must see only its own minimum, never the
      # global minimum across components.
      a_lo = subnet(1)
      a_hi = subnet(4)
      edge(a_lo, a_hi)

      b_lo = subnet(2)
      b_hi = subnet(3)
      edge(b_lo, b_hi)

      expect_unanimous_leader([a_lo, a_hi], a_lo)
      expect_unanimous_leader([b_lo, b_hi], b_lo)
    end

    context "with stress topologies" do
      it "chain: leader propagates across many hops" do
        # 1 - 2 - ... - 8, a path graph. The min-id node sits at one end;
        # the far end is 7 hops away. All must still resolve to it,
        # exercising CTE traversal depth.
        nodes = (1..8).map { subnet(it) }
        nodes.each_cons(2) { |a, b| edge(a, b) }
        expect_unanimous_leader(nodes, nodes.first)
      end

      it "chain with the minimum id in the middle" do
        # Path 5 - 3 - 1 - 2 - 4 by id, so the global minimum (1) is
        # interior, not an endpoint. Guards against dependence on traversal
        # start position.
        order = [5, 3, 1, 2, 4].map { subnet(it) }
        order.each_cons(2) { |a, b| edge(a, b) }
        expect_unanimous_leader(order, order.min_by(&:id))
      end

      it "star: hub plus many leaves" do
        hub = subnet(1)
        leaves = (2..7).map { subnet(it) }
        leaves.each { edge(hub, it) }
        expect_unanimous_leader([hub] + leaves, hub)
      end

      it "star with the minimum on a leaf, not the hub" do
        hub = subnet(5)
        leaves = (1..4).map { subnet(it) } + (6..8).map { subnet(it) }
        leaves.each { edge(hub, it) }
        expect_unanimous_leader([hub] + leaves, ([hub] + leaves).min_by(&:id))
      end

      it "clique: every subnet connected to every other" do
        # K6. Redundant edges and the resulting multiple CTE paths to each
        # node must not confuse the result or duplicate-explode.
        nodes = (1..6).map { subnet(it) }
        nodes.combination(2).each { |a, b| edge(a, b) }
        expect_unanimous_leader(nodes, nodes.first)
      end

      it "cycle: ring topology terminates and agrees" do
        # 1 - 2 - 3 - 4 - 5 - 1. The cycle is the specific reason the CTE
        # carries cycle: {columns: :id} and excludes is_cycle; without that
        # the recursion would not terminate. Fails loudly (timeout/dupe) if
        # that handling regresses.
        nodes = (1..5).map { subnet(it) }
        nodes.each_cons(2) { |a, b| edge(a, b) }
        edge(nodes.last, nodes.first)
        expect_unanimous_leader(nodes, nodes.first)
      end

      it "cycle with a tail (lollipop)" do
        # Ring 2-3-4-2 with pendant minimum 1 off node 2. Cycle handling
        # plus a one-hop extension to the true min.
        ring = [2, 3, 4].map { subnet(it) }
        ring.each_cons(2) { |a, b| edge(a, b) }
        edge(ring.last, ring.first)
        tail = subnet(1)
        edge(tail, ring.first)
        expect_unanimous_leader(ring + [tail], tail)
      end

      it "two cliques joined by a single bridge edge" do
        # K4 {1,3,5,7} and K4 {2,4,6,8}, joined by one edge 7-8. One
        # component, so the global min (1) wins everywhere, across the bridge.
        a = [1, 3, 5, 7].map { subnet(it) }
        b = [2, 4, 6, 8].map { subnet(it) }
        a.combination(2).each { |x, y| edge(x, y) }
        b.combination(2).each { |x, y| edge(x, y) }
        edge(a.last, b.last)
        expect_unanimous_leader(a + b, a.min_by(&:id))
      end

      it "barbell: two stars joined at their hubs" do
        hub_a = subnet(3)
        hub_b = subnet(6)
        leaves_a = [1, 4, 5].map { subnet(it) }
        leaves_b = [2, 7, 8].map { subnet(it) }
        leaves_a.each { edge(hub_a, it) }
        leaves_b.each { edge(hub_b, it) }
        edge(hub_a, hub_b)
        all = [hub_a, hub_b] + leaves_a + leaves_b
        expect_unanimous_leader(all, all.min_by(&:id))
      end
    end

    context "with edge cases that have bitten similar CTEs" do
      it "diamond: two distinct paths to the same node are not over-excluded" do
        # 1-2, 1-3, 2-4, 3-4: node 4 is reachable from 1 by two paths (via
        # 2 and via 3). Smallest genuine multi-path topology the schema
        # permits. A cycle guard that excised too aggressively could drop
        # node 4 on the second path; all four must still agree on the min.
        nodes = (1..4).map { subnet(it) }
        n1, n2, n3, n4 = nodes
        edge(n1, n2)
        edge(n1, n3)
        edge(n2, n4)
        edge(n3, n4)
        expect_unanimous_leader(nodes, n1)
      end

      it "agrees with find_all_connected_nics on component membership" do
        # connected_leader_id and find_all_connected_nics share a CTE shape;
        # their notions of "the component" must not drift. Build a mesh,
        # attach a nic per subnet, assert the leader is in the component
        # every subnet sees, for every subnet.
        nodes = [4, 1, 3, 2].map { subnet(it) }
        nodes.each_cons(2) { |a, b| edge(a, b) }
        nics = nodes.map do |ps|
          Nic.create_with_id(
            Nic.generate_uuid,
            private_subnet_id: ps.id,
            private_ipv6: ps.net6.nth(2).to_s,
            private_ipv4: ps.net4.nth(2).to_s,
            state: "active",
            name: "nic-#{ps.name}",
          )
        end
        leader_id = nodes.first.connected_leader_id
        nodes.each do |ps|
          component_subnet_ids = ps.find_all_connected_nics.map(&:private_subnet_id).uniq
          expect(component_subnet_ids).to include(leader_id),
            "leader #{leader_id} not in component seen by #{ps.name}"
        end
        expect(leader_id).to eq(nics.map(&:private_subnet_id).min)
      end
    end
  end

  describe "AWS connect/disconnect subnet" do
    let(:prj) { Project.create(name: "test-aws-prj") }

    let(:location) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id,
        display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      LocationCredentialAws.create_with_id(loc, access_key: "test-access-key", secret_key: "test-secret-key")
      LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
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

    it "raises error on connect_subnet" do
      expect { ps1.connect_subnet(ps2) }.to raise_error("Connected subnets are not supported for AWS")
    end

    it "raises error on disconnect_subnet" do
      expect { ps1.disconnect_subnet(ps2) }.to raise_error("Connected subnets are not supported for AWS")
    end
  end
end
