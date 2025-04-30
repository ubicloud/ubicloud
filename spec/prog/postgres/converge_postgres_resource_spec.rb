# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::ConvergePostgresResource do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:postgres_resource) {
    instance_double(
      PostgresResource,
      id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77",
      servers: [
        instance_double(PostgresServer),
        instance_double(PostgresServer)
      ],
      timeline: instance_double(PostgresTimeline, id: "timeline-id"),
      location: instance_double(Location, provider: "hetzner")
    )
  }

  before do
    allow(nx).to receive(:postgres_resource).and_return(postgres_resource)
  end

  describe "#start" do
    it "registers a deadline" do
      expect(nx).to receive(:register_deadline).with("recycle_representative_server", 2 * 60 * 60)
      expect { nx.start }.to hop("provision_servers")
    end
  end

  describe "#provision_servers" do
    before do
      allow(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(false)
      allow(postgres_resource.servers[0]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost, id: "vmh-id-1")))
      allow(postgres_resource.servers[1]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost, id: "vmh-id-2")))
    end

    it "hops to wait_servers_to_be_ready if there are enough fresh servers" do
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect { nx.provision_servers }.to hop("wait_servers_to_be_ready")
    end

    it "does not provision a new server if there is a server that is not assigned to a vm_host" do
      expect(postgres_resource.servers[0]).to receive(:vm).and_return(instance_double(Vm, vm_host: nil))
      expect(Prog::Postgres::PostgresServerNexus).not_to receive(:assemble)
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server without excluding hosts in development environment" do
      allow(Config).to receive(:development?).and_return(true)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: []))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server but excludes currently used data centers" do
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::HETZNER_PROVIDER_NAME)
      allow(postgres_resource.servers[0]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost, data_center: "dc1")))
      allow(postgres_resource.servers[1]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost, data_center: "dc2")))
      expect(VmHost).to receive(:where).with(data_center: ["dc1", "dc2"]).and_return([instance_double(VmHost, id: "vmh-id-1"), instance_double(VmHost, id: "vmh-id-2")])

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: ["vmh-id-1", "vmh-id-2"]))
      expect { nx.provision_servers }.to nap
    end
  end

  describe "#wait_servers_to_be_ready" do
    it "hops to provision_servers if there is not enough fresh servers" do
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(false)
      expect { nx.wait_servers_to_be_ready }.to hop("provision_servers")
    end

    it "hops to recycle_representative_server if there are enough ready servers" do
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect(postgres_resource).to receive(:has_enough_ready_servers?).and_return(true)
      expect { nx.wait_servers_to_be_ready }.to hop("recycle_representative_server")
    end

    it "waits if there are not enough ready servers" do
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect(postgres_resource).to receive(:has_enough_ready_servers?).and_return(false)
      expect { nx.wait_servers_to_be_ready }.to nap
    end
  end

  describe "#recycle_representative_server" do
    it "waits until there is a representative server to act on it" do
      expect(postgres_resource).to receive(:representative_server).and_return(nil)
      expect { nx.recycle_representative_server }.to nap
    end

    it "hops to prune_servers if the representative server does not need recycling" do
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, needs_recycling?: false)).at_least(:once)
      expect { nx.recycle_representative_server }.to hop("prune_servers")
    end

    it "waits if it is not the maintenance window" do
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, needs_recycling?: true)).at_least(:once)
      expect(postgres_resource).to receive(:maintenance_window_start_at).and_return(4)
      expect(Time).to receive(:now).and_return(Time.utc(2025, 1, 1, 1))
      expect(postgres_resource.representative_server).not_to receive(:trigger_failover)
      expect { nx.recycle_representative_server }.to nap(10 * 60)
    end

    it "triggers failover if maintenance window is not set or if it is the maintenance window" do
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, needs_recycling?: true)).at_least(:once)
      expect(postgres_resource).to receive(:maintenance_window_start_at).and_return(nil, 4)
      expect(Time).to receive(:now).and_return(Time.utc(2025, 1, 1, 5)).at_least(:once)
      expect(postgres_resource.representative_server).to receive(:trigger_failover).twice
      expect { nx.recycle_representative_server }.to nap(60)
      expect { nx.recycle_representative_server }.to nap(60)
    end
  end

  describe "#prune_servers" do
    it "destroys extra servers" do
      expect(postgres_resource).to receive(:servers).and_return([
        instance_double(PostgresServer, representative_at: "yesterday", needs_recycling?: false, created_at: 1, strand: instance_double(Strand, label: "wait")),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: true, created_at: 5, strand: instance_double(Strand, label: "wait")),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 4, strand: instance_double(Strand, label: "unavailable")),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 3, strand: instance_double(Strand, label: "wait")),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 2, strand: instance_double(Strand, label: "wait"))
      ]).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(postgres_resource.servers[0])
      expect(postgres_resource).to receive(:target_standby_count).and_return(1).at_least(:once)

      expect(postgres_resource.servers[1]).to receive(:incr_destroy)
      expect(postgres_resource.servers[2]).to receive(:incr_destroy)
      expect(postgres_resource.servers[4]).to receive(:incr_destroy)

      expect(postgres_resource).to receive(:incr_update_billing_records)

      expect { nx.prune_servers }.to exit
    end
  end
end
