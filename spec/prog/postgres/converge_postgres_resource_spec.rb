# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::ConvergePostgresResource do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:postgres_resource) {
    instance_double(
      PostgresResource,
      id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77",
      ubid: "pgg54eqqv6q26kgqrszmkypn7f",
      servers: [
        instance_double(PostgresServer),
        instance_double(PostgresServer)
      ],
      timeline: instance_double(PostgresTimeline, id: "timeline-id"),
      location: instance_double(Location, aws?: false),
      target_version: "17"
    )
  }

  before do
    allow(nx).to receive(:postgres_resource).and_return(postgres_resource)
  end

  describe "#start" do
    it "registers a deadline" do
      expect(nx).to receive(:register_deadline).with("wait_for_maintenance_window", 2 * 60 * 60)
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

    it "provisions a new server without excluding hosts when Config.allow_unspread_servers is true" do
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::HETZNER_PROVIDER_NAME).at_least(:once)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: []))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server but excludes currently used data centers" do
      allow(Config).to receive(:allow_unspread_servers).and_return(false)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::HETZNER_PROVIDER_NAME).at_least(:once)
      allow(postgres_resource.servers[0]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost, data_center: "dc1")))
      allow(postgres_resource.servers[1]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost, data_center: "dc2")))
      expect(VmHost).to receive(:where).with(data_center: ["dc1", "dc2"]).and_return([instance_double(VmHost, id: "vmh-id-1"), instance_double(VmHost, id: "vmh-id-2")])

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: ["vmh-id-1", "vmh-id-2"]))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server but excludes currently used az for aws" do
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME).at_least(:once)
      allow(postgres_resource.servers[0]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "a"))))
      allow(postgres_resource.servers[1]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "b"))))
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: ["a", "b"]))
      expect(postgres_resource).to receive(:use_different_az_set?).and_return(true)
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server in a used az for aws if use_different_az_set? is false" do
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME).at_least(:once)
      allow(postgres_resource.servers[0]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "a"))))
      allow(postgres_resource.servers[1]).to receive(:vm).and_return(instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "b"))))
      expect(postgres_resource).to receive(:representative_server).and_return(postgres_resource.servers[0])
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(availability_zone: "a"))
      expect(postgres_resource).to receive(:use_different_az_set?).and_return(false)
      expect { nx.provision_servers }.to nap
    end
  end

  describe "#wait_servers_to_be_ready" do
    it "hops to provision_servers if there is not enough fresh servers" do
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(false)
      expect { nx.wait_servers_to_be_ready }.to hop("provision_servers")
    end

    it "hops to wait_for_maintenance_window if there are enough ready servers" do
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect(postgres_resource).to receive(:has_enough_ready_servers?).and_return(true)
      expect { nx.wait_servers_to_be_ready }.to hop("wait_for_maintenance_window")
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
      expect(postgres_resource).to receive(:ongoing_failover?).and_return(false)
      expect { nx.recycle_representative_server }.to hop("prune_servers")
    end

    it "hops to provision_servers if there are not enough ready servers" do
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, needs_recycling?: true)).at_least(:once)
      expect(postgres_resource).to receive(:ongoing_failover?).and_return(false)
      expect(postgres_resource).to receive(:has_enough_ready_servers?).and_return(false)
      expect { nx.recycle_representative_server }.to hop("provision_servers")
    end

    it "triggers failover directly when called" do
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, needs_recycling?: true)).at_least(:once)
      expect(postgres_resource).to receive(:ongoing_failover?).and_return(false)
      expect(postgres_resource).to receive(:has_enough_ready_servers?).and_return(true)
      expect(postgres_resource.representative_server).to receive(:trigger_failover)
      expect { nx.recycle_representative_server }.to nap(60)
    end
  end

  describe "#wait_for_maintenance_window" do
    it "hops to provision_servers if there are not enough fresh servers" do
      expect(postgres_resource).to receive(:in_maintenance_window?).and_return(true)
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(false)
      expect { nx.wait_for_maintenance_window }.to hop("provision_servers")
    end

    it "hops to recycle_representative_server if in maintenance window and not upgrading" do
      expect(postgres_resource).to receive(:in_maintenance_window?).and_return(true)
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect(postgres_resource).to receive(:version).and_return("16")
      expect(postgres_resource).to receive(:target_version).and_return("16")
      expect { nx.wait_for_maintenance_window }.to hop("recycle_representative_server")
    end

    it "fences primary and hops to wait_fence_primary if in maintenance window and upgrading" do
      expect(postgres_resource).to receive(:in_maintenance_window?).and_return(true)
      expect(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect(postgres_resource).to receive(:version).and_return("16")
      expect(postgres_resource).to receive(:target_version).and_return("17")
      primary = instance_double(PostgresServer, version: "16")
      expect(postgres_resource).to receive(:representative_server).and_return(primary)
      expect(primary).to receive(:incr_fence)
      expect { nx.wait_for_maintenance_window }.to hop("wait_fence_primary")
    end

    it "waits if not in maintenance window" do
      expect(postgres_resource).to receive(:in_maintenance_window?).and_return(false)
      expect { nx.wait_for_maintenance_window }.to nap(10 * 60)
    end
  end

  describe "#wait_fence_primary" do
    it "hops to upgrade_standby when primary is fenced" do
      primary = instance_double(PostgresServer, strand: instance_double(Strand, label: "wait_in_fence"))
      expect(postgres_resource).to receive(:representative_server).and_return(primary)
      expect { nx.wait_fence_primary }.to hop("upgrade_standby")
    end

    it "waits when primary is not yet fenced" do
      primary = instance_double(PostgresServer, strand: instance_double(Strand, label: "wait"))
      expect(postgres_resource).to receive(:representative_server).and_return(primary)
      expect { nx.wait_fence_primary }.to nap(5)
    end
  end

  describe "#upgrade_standby" do
    let(:candidate) { instance_double(PostgresServer, vm: instance_double(Vm, sshable: Sshable.new)) }

    before do
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
    end

    it "hops to update_metadata when upgrade succeeds" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("Succeeded")
      expect(candidate.vm.sshable).to receive(:d_clean).with("upgrade_postgres")
      expect { nx.upgrade_standby }.to hop("update_metadata")
    end

    it "hops to upgrade_failed when upgrade fails" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("Failed")
      expect { nx.upgrade_standby }.to hop("upgrade_failed")
    end

    it "starts upgrade when not started" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("NotStarted")
      expect(postgres_resource).to receive(:target_version).and_return("17")
      expect(candidate.vm.sshable).to receive(:d_run).with("upgrade_postgres", "sudo", "postgres/bin/upgrade", "17")
      expect { nx.upgrade_standby }.to nap(5)
    end

    it "naps if status of the upgrade is unknown" do
      expect(candidate.vm.sshable).to receive(:d_check).with("upgrade_postgres").and_return("Unknown")
      expect { nx.upgrade_standby }.to nap(5)
    end
  end

  describe "#update_metadata" do
    let(:candidate) { instance_double(PostgresServer) }
    let(:new_timeline) { instance_double(Strand, id: "new_timeline_id") }

    before do
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
    end

    it "creates new timeline and updates candidate server metadata and hops to recycle_representative_server" do
      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).with(location_id: anything).and_return(new_timeline)
      expect(postgres_resource).to receive(:location_id).and_return("location_id")
      expect(postgres_resource).to receive(:target_version).and_return("17")

      expect(candidate).to receive(:update).with(version: "17", timeline_id: "new_timeline_id", timeline_access: "push")
      expect(candidate).to receive(:incr_refresh_walg_credentials)
      expect(candidate).to receive(:incr_configure)
      expect(candidate).to receive(:incr_restart)

      expect { nx.update_metadata }.to hop("wait_upgrade_candidate")
    end
  end

  describe "#wait_upgrade_candidate" do
    it "hops to recycle_representative_server when candidate is ready" do
      candidate = instance_double(PostgresServer, restart_set?: false, strand: instance_double(Strand, label: "wait"))
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      expect { nx.wait_upgrade_candidate }.to hop("recycle_representative_server")
    end

    it "waits when candidate is waiting for restart" do
      candidate = instance_double(PostgresServer, restart_set?: true)
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      expect { nx.wait_upgrade_candidate }.to nap(5)
    end

    it "waits when candidate is not ready" do
      candidate = instance_double(PostgresServer, restart_set?: false, strand: instance_double(Strand, label: "configure"))
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      expect { nx.wait_upgrade_candidate }.to nap(5)
    end
  end

  describe "#upgrade_failed" do
    let(:candidate) { instance_double(PostgresServer, vm: instance_double(Vm, sshable: Sshable.new)) }
    let(:primary) { instance_double(PostgresServer, strand: instance_double(Strand, label: "wait_in_fence")) }

    before do
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      allow(postgres_resource).to receive(:representative_server).and_return(primary)
    end

    it "logs failure, raises a page and destroys candidate server" do
      expect(candidate).to receive(:destroy_set?).and_return(false)
      expect(candidate.vm.sshable).to receive(:_cmd).with("sudo journalctl -u upgrade_postgres").and_return("log line 1\nlog line 2")
      expect(Clog).to receive(:emit).with("Postgres resource upgrade failed").and_yield.twice
      expect(candidate).to receive(:incr_destroy)
      expect(primary).to receive(:incr_unfence)
      expect(postgres_resource).to receive(:id).at_least(:once).and_return("resource_id")
      expect(Prog::PageNexus).to receive(:assemble).with("#{postgres_resource.ubid} upgrade failed", ["PostgresUpgradeFailed", postgres_resource.id], postgres_resource.ubid)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "unfences primary if it is fenced" do
      allow(candidate).to receive(:destroy_set?).and_return(false)
      allow(candidate.vm.sshable).to receive(:_cmd).and_return("")
      allow(Clog).to receive(:emit)
      expect(candidate).to receive(:incr_destroy)
      expect(primary).to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "does not unfence if primary is not fenced" do
      allow(primary).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      allow(candidate.vm.sshable).to receive(:_cmd).and_return("")
      allow(candidate).to receive(:destroy_set?).and_return(false)
      allow(Clog).to receive(:emit)
      expect(candidate).to receive(:incr_destroy)
      expect(primary).not_to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "handles case when candidate is nil" do
      allow(nx).to receive(:upgrade_candidate).and_return(nil)
      allow(primary).to receive(:incr_unfence) # Allow but don't expect since logic still runs

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "handles case when candidate is not nil but destroy_set? is true" do
      allow(candidate).to receive(:destroy_set?).and_return(true)
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      allow(primary).to receive(:incr_unfence) # Allow but don't expect since logic still runs

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end
  end

  describe "#prune_servers" do
    it "destroys extra servers but keeps those that don't need recycling and match current version" do
      expect(postgres_resource).to receive(:servers).and_return([
        instance_double(PostgresServer, representative_at: "yesterday", needs_recycling?: false, created_at: 1, strand: instance_double(Strand, label: "wait"), version: "17"),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: true, created_at: 5, strand: instance_double(Strand, label: "wait"), version: "17"),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 4, strand: instance_double(Strand, label: "unavailable"), version: "17"),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 3, strand: instance_double(Strand, label: "wait"), version: "17"),
        instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 2, strand: instance_double(Strand, label: "wait"), version: "17")
      ]).at_least(:once)
      expect(postgres_resource).to receive(:target_version).and_return("17").at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(postgres_resource.servers[0])
      expect(postgres_resource).to receive(:target_standby_count).and_return(1).at_least(:once)

      expect(postgres_resource.servers[1]).to receive(:incr_destroy)
      expect(postgres_resource.servers[2]).to receive(:incr_destroy)
      expect(postgres_resource.servers[4]).to receive(:incr_destroy)

      expect(postgres_resource.servers[0]).to receive(:incr_configure)
      expect(postgres_resource.servers[3]).to receive(:incr_configure)
      expect(postgres_resource).to receive(:incr_update_billing_records)

      expect { nx.prune_servers }.to exit
    end

    it "destroys servers with older versions" do
      old_server = instance_double(PostgresServer, version: "16", representative_at: nil, needs_recycling?: false, created_at: 1, strand: instance_double(Strand, label: "wait"))
      new_server = instance_double(PostgresServer, version: "17", representative_at: "yesterday", needs_recycling?: false, created_at: 2, strand: instance_double(Strand, label: "wait"))
      expect(postgres_resource).to receive(:servers).and_return([old_server, new_server]).at_least(:once)
      expect(postgres_resource).to receive(:target_version).and_return("17").at_least(:once)
      expect(old_server).to receive(:incr_destroy)

      # Mock the normal pruning logic
      expect(postgres_resource).to receive(:representative_server).and_return(new_server)
      expect(postgres_resource).to receive(:target_standby_count).and_return(0)
      expect(new_server).to receive(:incr_configure)
      expect(postgres_resource).to receive(:incr_update_billing_records)

      expect { nx.prune_servers }.to exit
    end
  end

  describe "#upgrade_candidate" do
    it "returns the upgrade candidate server" do
      expect(postgres_resource).to receive(:upgrade_candidate_server).at_least(:once).and_return(instance_double(PostgresServer, version: "16"))
      expect(nx.upgrade_candidate).to eq(postgres_resource.upgrade_candidate_server)
    end
  end
end
