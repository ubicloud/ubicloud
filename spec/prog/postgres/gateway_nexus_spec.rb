# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::GatewayNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "ember-service") }

  let(:gateway) {
    PostgresGateway.create(location_id: Location::HETZNER_FSN1_ID,
      hostname_suffix: "ember.test", replica_count: 2)
  }

  let(:strand) { Strand.create_with_id(gateway, prog: "Postgres::GatewayNexus", label: "wait") }

  before do
    allow(Config).to receive(:ember_service_project_id).and_return(project.id)
  end

  describe ".assemble" do
    it "creates one fleet per location" do
      gw = described_class.assemble(Location::HETZNER_FSN1_ID, hostname_suffix: "ember.example", replica_count: 3)
      expect(gw.hostname_suffix).to eq("ember.example")
      expect(gw.replica_count).to eq(3)
      expect(Strand[gw.id].label).to eq("start")
    end

    it "takes the defaults from configuration" do
      gw = described_class.assemble(Location::HETZNER_FSN1_ID)
      expect(gw.hostname_suffix).to eq(Config.postgres_gateway_hostname_suffix)
      expect(gw.replica_count).to eq(Config.postgres_gateway_replica_count)
    end

    it "refuses a second fleet in the same location" do
      gateway
      expect { described_class.assemble(Location::HETZNER_FSN1_ID) }
        .to raise_error(RuntimeError, /already exists/)
    end
  end

  describe "#start" do
    it "gives the fleet a private subnet of its own" do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet-start").subject
      expect(Prog::Vnet::SubnetNexus).to receive(:assemble)
        .and_return(instance_double(Strand, subject: subnet))
      expect { nx.start }.to hop("create_load_balancer")
      expect(gateway.reload.private_subnet_id).to eq(subnet.id)
    end

    it "refuses to run without a service project to own the fleet" do
      allow(Config).to receive(:ember_service_project_id).and_return(nil)
      expect { nx.start }.to raise_error(RuntimeError, /ember_service_project_id/)
    end
  end

  describe "#create_load_balancer" do
    let(:subnet) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet").subject }

    before do
      strand
      gateway.update(private_subnet_id: subnet.id)
    end

    it "waits for the subnet before asking for a load balancer" do
      subnet.strand.update(label: "wait_setup")
      expect { nx.create_load_balancer }.to nap(5)
    end

    it "asks for TCP passthrough on 5432, because the gateway terminates TLS itself" do
      subnet.strand.update(label: "wait")
      lb = LoadBalancer.create(private_subnet_id: subnet.id, project_id: project.id, name: "ember-lb",
        algorithm: "round_robin", health_check_endpoint: "/", stack: LoadBalancer::Stack::DUAL)
      expect(Prog::Vnet::LoadBalancerNexus).to receive(:assemble) { |_id, **args|
        expect(args[:src_port]).to eq(5432)
        expect(args[:dst_port]).to eq(5432)
        expect(args[:health_check_protocol]).to eq("tcp")
        instance_double(Strand, subject: lb)
      }
      expect { nx.create_load_balancer }.to hop("wait_replicas")
      expect(gateway.reload.load_balancer_id).to eq(lb.id)
    end
  end

  describe "#wait_replicas" do
    before { strand }

    it "creates as many replicas as the fleet is short" do
      expect(Prog::Postgres::GatewayReplicaNexus).to receive(:assemble).twice
      expect { nx.wait_replicas }.to hop("wait")
    end

    it "creates none when the fleet is already the size it should be" do
      gateway.update(replica_count: 0)
      expect(Prog::Postgres::GatewayReplicaNexus).not_to receive(:assemble)
      expect { nx.wait_replicas }.to hop("wait")
    end
  end

  describe "#wait" do
    before do
      strand
      gateway.update(replica_count: 0)
    end

    it "tears the fleet down on request" do
      gateway.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "pushes to the hosts on request" do
      gateway.incr_reconfigure
      expect { nx.wait }.to hop("push_hosts")
      expect(gateway.reload.semaphores).to be_empty
    end

    it "pushes to the hosts when the set of replica addresses has changed" do
      expect { nx.wait }.to hop("push_hosts")
    end

    # A fresh prog runs every label, so what was pushed has to be in the
    # strand's frame; an instance variable would read as nothing pushed yet
    # and send wait straight back to push_hosts.
    it "settles once the sources are pushed, however many hops later" do
      expect { nx.push_hosts }.to hop("wait")
      strand.save_changes
      expect { described_class.new(Strand[strand.id]).wait }.to nap(described_class::WAIT_SECONDS)
    end

    it "makes up the count when a replica has gone" do
      nx.pushed_sources = []
      gateway.update(replica_count: 1)
      expect { nx.wait }.to hop("wait_replicas")
    end

    it "peers with a host that has started taking embers" do
      nx.pushed_sources = gateway.source_prefixes
      create_ember_host
      expect { nx.wait }.to hop("sync_hosts")
    end

    it "rotates a host end's key when that is due" do
      nx.pushed_sources = gateway.source_prefixes
      host = gateway_host
      host.update(tunnel_rekeyed_at: Time.now - EmberTunnel::REKEY_INTERVAL - 1)
      expect { nx.wait }.to hop("rekey_hosts")
    end

    it "pushes a host end again every so often, in case a reboot emptied it" do
      nx.pushed_sources = gateway.source_prefixes
      host = gateway_host
      host.update(tunnel_pushed_at: Time.now - EmberTunnel::REAPPLY_INTERVAL - 1)
      expect(EmberTunnel).to receive(:push) { |record| expect(record.id).to eq(host.id) }
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end

    it "settles once nothing has changed" do
      nx.pushed_sources = gateway.source_prefixes
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end
  end

  def gateway_host(vm_host = create_ember_host)
    host = PostgresGatewayHost.create_with_id(vm_host.id, postgres_gateway_id: gateway.id, tunnel_pushed_at: Time.now)
    EmberTunnel.ensure_keys(host)
    host
  end

  describe "#sync_hosts" do
    before { strand }

    it "has the replicas learn a new host before the host's own end is pushed" do
      vm_host = create_ember_host
      replica = create_gateway_replica
      expect(EmberTunnel).to receive(:push_peers).ordered { |record| expect(record.id).to eq(vm_host.id) }
      expect(EmberTunnel).to receive(:push).ordered { |record| expect(record.id).to eq(vm_host.id) }
      expect { nx.sync_hosts }.to hop("push_hosts")
      expect(JSON.parse(PostgresGatewayHost[vm_host.id].tunnel_keys)["keys"].size).to eq(1)
      expect(replica.reload.semaphores.map(&:name)).to include("reconfigure")
    end

    it "stops peering with a host that no longer takes embers" do
      host = gateway_host
      host.vm_host.update(accepts_embers: false)
      expect { nx.sync_hosts }.to hop("push_hosts")
      expect(host).not_to exist
    end

    it "tries again shortly when a replica cannot be reached" do
      create_ember_host
      expect(EmberTunnel).to receive(:push_peers).and_raise(EmberTunnel::PushFailed, "could not reach gk1")
      expect { nx.sync_hosts }.to nap(30)
    end
  end

  describe "#rekey_hosts" do
    before { strand }

    it "rotates the keys that are due, then goes back to waiting" do
      host = gateway_host
      host.update(tunnel_rekeyed_at: nil)
      gateway_host
      expect(EmberTunnel).to receive(:rekey).once { |record| expect(record.id).to eq(host.id) }
      expect { nx.rekey_hosts }.to hop("wait")
    end

    it "tries again shortly when a replica cannot be reached" do
      gateway_host.update(tunnel_rekeyed_at: nil)
      expect(EmberTunnel).to receive(:rekey).and_raise(EmberTunnel::PushFailed, "could not reach gk1")
      expect { nx.rekey_hosts }.to nap(30)
    end
  end

  describe "#push_hosts" do
    before { strand }

    it "tells every ember host its IPsec peers and which addresses to accept" do
      host = gateway_host
      vm = create_vm(vm_host_id: create_vm_host.id, ephemeral_net6: "2a01:4f8:10a:1:2::/79")
      EmberTunnel.ensure_keys(create_gateway_replica(vm:))
      expect(EmberTunnel).to receive(:push) { |record| expect(record.id).to eq(host.id) }
      commands = []
      on_ember_command { |command, kw|
        commands << [command, JSON.parse(kw[:stdin])]
        {}
      }
      expect { nx.push_hosts }.to hop("wait")
      # The guest half of the replica's block, which it speaks from inside the
      # IPsec mesh.
      expect(commands).to eq([["ingress-sources", {"ingress_sources" => ["2a01:4f8:10a:1:2::/80"]}]])
    end

    it "keeps going when one host cannot be reached" do
      gateway_host
      expect(EmberTunnel).to receive(:push).and_raise(Sshable::SshError.new("x", "", "", nil, nil))
      expect { nx.push_hosts }.to hop("wait")
    end
  end

  describe "#destroy" do
    before { strand }

    it "waits for its replicas to go first" do
      replica = create_gateway_replica
      expect { nx.destroy }.to nap(10)
      expect(replica.reload.semaphores.map(&:name)).to include("destroy")
    end

    it "goes anyway when it never got as far as a load balancer" do
      expect { nx.destroy }.to exit({"msg" => "ember gateway destroyed"})
      expect(PostgresGateway[gateway.id]).to be_nil
    end

    it "takes the load balancer and the subnet with it" do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-destroy-subnet").subject
      lb = LoadBalancer.create(private_subnet_id: subnet.id, project_id: project.id,
        name: "ember-lb", algorithm: "round_robin", health_check_endpoint: "/", stack: LoadBalancer::Stack::DUAL)
      Strand.create_with_id(lb, prog: "Vnet::LoadBalancerNexus", label: "wait")
      gateway.update(load_balancer_id: lb.id, private_subnet_id: lb.private_subnet_id)
      expect { nx.destroy }.to exit({"msg" => "ember gateway destroyed"})
      expect(lb.reload.semaphores.map(&:name)).to include("destroy")
      expect(PostgresGateway[gateway.id]).to be_nil
    end
  end

  def create_gateway_replica(vm: create_vm, **args)
    replica = PostgresGatewayReplica.create(postgres_gateway_id: gateway.id, vm_id: vm.id, **args)
    # Semaphores only insert where a strand with that id already exists.
    Strand.create_with_id(replica, prog: "Postgres::GatewayReplicaNexus", label: "wait")
    replica
  end
end
