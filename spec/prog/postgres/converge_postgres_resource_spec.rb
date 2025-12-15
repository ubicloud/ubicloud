# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::ConvergePostgresResource do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "converge-test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:timeline) { PostgresTimeline.create(location_id: location_id) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id: location_id,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  let(:postgres_resource) {
    pr = PostgresResource.create(
      name: "pg-test", superuser_password: "dummy-password", ha_type: "none",
      target_version: "17", location_id: location_id, project_id: project.id,
      user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
      target_storage_size_gib: 64, private_subnet_id: private_subnet.id
    )
    Strand.create_with_id(pr.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  }

  let(:strand) {
    Strand.create(
      prog: "Postgres::ConvergePostgresResource", label: "start",
      parent_id: postgres_resource.strand.id,
      stack: [{"subject_id" => postgres_resource.id}]
    )
  }

  before do
    allow(nx).to receive(:postgres_resource).and_return(postgres_resource)
  end

  def create_server(version: "17", representative: false, vm_host_data_center: nil, timeline: self.timeline, timeline_access: "fetch", resource: postgres_resource)
    vm_host = create_vm_host(location_id: resource.location_id, data_center: vm_host_data_center)
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "pg-vm-#{SecureRandom.hex(4)}", private_subnet_id: resource.private_subnet_id,
      location_id: resource.location_id, unix_user: "ubi"
    ).subject
    vm.update(vm_host_id: vm_host.id)
    server = PostgresServer.create(
      timeline: timeline, resource_id: resource.id, vm_id: vm.id,
      representative_at: representative ? Time.now : nil,
      synchronization_status: "ready", timeline_access: timeline_access, version: version
    )
    Strand.create_with_id(server.id, prog: "Postgres::PostgresServerNexus", label: "wait")
    server
  end

  def create_mock_sshable_for_vm(vm)
    sshable = create_mock_sshable(host: "1.1.1.1")
    allow(vm).to receive(:sshable).and_return(sshable)
    sshable
  end

  it "exits if destroy is set" do
    expect(nx).to receive(:when_destroy_set?).and_yield
    expect { nx.before_run }.to exit({"msg" => "exiting early due to destroy semaphore"})
  end

  describe "#start" do
    it "naps if read replica parent is not ready" do
      parent = PostgresResource.create(
        name: "pg-parent", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: location_id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64, private_subnet_id: private_subnet.id
      )
      Strand.create_with_id(parent.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
      postgres_resource.update(parent_id: parent.id)
      allow(parent).to receive(:ready_for_read_replica?).and_return(false)
      allow(postgres_resource).to receive(:parent).and_return(parent)

      expect { nx.start }.to nap(60)
    end

    it "registers a deadline and hops to provision_servers if read replica parent is ready" do
      parent = PostgresResource.create(
        name: "pg-parent2", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: location_id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64, private_subnet_id: private_subnet.id
      )
      Strand.create_with_id(parent.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
      postgres_resource.update(parent_id: parent.id)
      allow(parent).to receive(:ready_for_read_replica?).and_return(true)
      allow(postgres_resource).to receive(:parent).and_return(parent)

      expect(nx).to receive(:register_deadline).with("wait_for_maintenance_window", 2 * 60 * 60)
      expect { nx.start }.to hop("provision_servers")
    end
  end

  describe "#provision_servers" do
    before do
      strand.update(label: "provision_servers")
      create_server(representative: true, vm_host_data_center: "dc1")
      create_server(representative: false, vm_host_data_center: "dc2")
    end

    it "hops to wait_servers_to_be_ready if there are enough fresh servers" do
      allow(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(true)
      expect { nx.provision_servers }.to hop("wait_servers_to_be_ready")
    end

    it "does not provision a new server if there is a server that is not assigned to a vm_host" do
      server = postgres_resource.servers.first
      server.vm.update(vm_host_id: nil)
      expect(Prog::Postgres::PostgresServerNexus).not_to receive(:assemble)
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server without excluding hosts when Config.allow_unspread_servers is true for regular instances" do
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: []))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server but excludes currently used data centers" do
      allow(Config).to receive(:allow_unspread_servers).and_return(false)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble) do |**kwargs|
        expect(kwargs[:exclude_host_ids].size).to eq(2)
      end
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server but excludes currently used az for aws" do
      servers = [
        instance_double(PostgresServer, needs_recycling?: false, version: "17", vm: instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "a")))),
        instance_double(PostgresServer, needs_recycling?: false, version: "17", vm: instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "b"))))
      ]
      allow(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME)
      allow(postgres_resource).to receive_messages(servers: servers, has_enough_fresh_servers?: false, use_different_az_set?: true)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: contain_exactly("a", "b")))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server in a used az for aws if use_different_az_set? is false" do
      representative_server = instance_double(
        PostgresServer,
        needs_recycling?: false,
        version: "17",
        representative_at: Time.now,
        vm: instance_double(Vm, vm_host: instance_double(VmHost), nic: instance_double(Nic, nic_aws_resource: instance_double(NicAwsResource, subnet_az: "a")))
      )
      servers = [representative_server]
      allow(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME)
      allow(postgres_resource).to receive_messages(servers: servers, has_enough_fresh_servers?: false, representative_server: representative_server, use_different_az_set?: false)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(availability_zone: "a"))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server with the correct timeline for a regular instance" do
      allow(Config).to receive(:allow_unspread_servers).and_return(true)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(timeline_id: timeline.id))
      expect { nx.provision_servers }.to nap
    end

    it "provisions a new server with the correct timeline for a read replica" do
      parent_timeline = PostgresTimeline.create(location_id: location_id)
      parent = PostgresResource.create(
        name: "pg-parent3", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: location_id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64, private_subnet_id: private_subnet.id
      )
      Strand.create_with_id(parent.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
      # Create a server for parent so it has a timeline
      create_server(timeline: parent_timeline, representative: true, timeline_access: "push", resource: parent)

      postgres_resource.update(parent_id: parent.id)
      allow(Config).to receive(:allow_unspread_servers).and_return(true)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(timeline_id: parent_timeline.id))
      expect { nx.provision_servers }.to nap
    end
  end

  describe "#wait_servers_to_be_ready" do
    before do
      strand.update(label: "wait_servers_to_be_ready")
    end

    it "hops to provision_servers if there is not enough fresh servers" do
      allow(postgres_resource).to receive(:has_enough_fresh_servers?).and_return(false)
      expect { nx.wait_servers_to_be_ready }.to hop("provision_servers")
    end

    it "hops to wait_for_maintenance_window if there are enough ready servers" do
      allow(postgres_resource).to receive_messages(has_enough_fresh_servers?: true, has_enough_ready_servers?: true)
      expect { nx.wait_servers_to_be_ready }.to hop("wait_for_maintenance_window")
    end

    it "waits if there are not enough ready servers" do
      allow(postgres_resource).to receive_messages(has_enough_fresh_servers?: true, has_enough_ready_servers?: false)
      expect { nx.wait_servers_to_be_ready }.to nap
    end
  end

  describe "#recycle_representative_server" do
    before do
      strand.update(label: "recycle_representative_server")
    end

    it "waits until there is a representative server to act on it" do
      expect { nx.recycle_representative_server }.to nap
    end

    it "hops to prune_servers if the representative server does not need recycling" do
      server = create_server(representative: true)
      allow(server).to receive(:needs_recycling?).and_return(false)
      allow(postgres_resource).to receive_messages(representative_server: server, ongoing_failover?: false)
      expect { nx.recycle_representative_server }.to hop("prune_servers")
    end

    it "hops to provision_servers if there are not enough ready servers" do
      server = create_server(representative: true)
      allow(server).to receive(:needs_recycling?).and_return(true)
      allow(postgres_resource).to receive_messages(representative_server: server, ongoing_failover?: false, has_enough_ready_servers?: false)
      expect { nx.recycle_representative_server }.to hop("provision_servers")
    end

    it "triggers failover directly when called" do
      server = create_server(representative: true)
      allow(server).to receive(:needs_recycling?).and_return(true)
      allow(postgres_resource).to receive_messages(representative_server: server, ongoing_failover?: false, has_enough_ready_servers?: true)
      expect(server).to receive(:trigger_failover)
      expect { nx.recycle_representative_server }.to nap(60)
    end
  end

  describe "#wait_for_maintenance_window" do
    before do
      strand.update(label: "wait_for_maintenance_window")
    end

    it "hops to provision_servers if there are not enough fresh servers" do
      allow(postgres_resource).to receive_messages(in_maintenance_window?: true, has_enough_fresh_servers?: false)
      expect { nx.wait_for_maintenance_window }.to hop("provision_servers")
    end

    it "hops to recycle_representative_server if in maintenance window and not upgrading" do
      allow(postgres_resource).to receive_messages(in_maintenance_window?: true, has_enough_fresh_servers?: true, version: "16", target_version: "16")
      expect { nx.wait_for_maintenance_window }.to hop("recycle_representative_server")
    end

    it "fences primary and hops to wait_fence_primary if in maintenance window and upgrading for regular instances" do
      server = create_server(representative: true, version: "16")
      allow(postgres_resource).to receive_messages(in_maintenance_window?: true, has_enough_fresh_servers?: true, version: "16", representative_server: server)
      expect(server).to receive(:incr_fence)
      expect { nx.wait_for_maintenance_window }.to hop("wait_fence_primary")
    end

    it "fences primary and hops to recycle_representative_server if in maintenance window and upgrading for read replicas" do
      parent = PostgresResource.create(
        name: "pg-parent-maint", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: location_id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64, private_subnet_id: private_subnet.id
      )
      Strand.create_with_id(parent.id, prog: "Postgres::PostgresResourceNexus", label: "wait")
      postgres_resource.update(parent_id: parent.id)

      allow(postgres_resource).to receive_messages(in_maintenance_window?: true, has_enough_fresh_servers?: true, version: "16")
      expect { nx.wait_for_maintenance_window }.to hop("recycle_representative_server")
    end

    it "waits if not in maintenance window" do
      allow(postgres_resource).to receive(:in_maintenance_window?).and_return(false)
      expect { nx.wait_for_maintenance_window }.to nap(10 * 60)
    end
  end

  describe "#wait_fence_primary" do
    before do
      strand.update(label: "wait_fence_primary")
    end

    it "hops to upgrade_standby when primary is fenced" do
      server = create_server(representative: true)
      server.strand.update(label: "wait_in_fence")
      expect { nx.wait_fence_primary }.to hop("upgrade_standby")
    end

    it "waits when primary is not yet fenced" do
      create_server(representative: true)
      expect { nx.wait_fence_primary }.to nap(5)
    end
  end

  describe "#upgrade_standby" do
    let(:candidate) { create_server(version: "16") }
    let(:sshable) { create_mock_sshable_for_vm(candidate.vm) }

    before do
      strand.update(label: "upgrade_standby")
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
    end

    it "hops to update_metadata when upgrade succeeds" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("upgrade_postgres")
      expect { nx.upgrade_standby }.to hop("update_metadata")
    end

    it "hops to upgrade_failed when upgrade fails" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("Failed")
      expect { nx.upgrade_standby }.to hop("upgrade_failed")
    end

    it "starts upgrade when not started" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("upgrade_postgres", "sudo", "postgres/bin/upgrade", "17")
      expect { nx.upgrade_standby }.to nap(5)
    end

    it "naps if status of the upgrade is unknown" do
      expect(sshable).to receive(:d_check).with("upgrade_postgres").and_return("Unknown")
      expect { nx.upgrade_standby }.to nap(5)
    end
  end

  describe "#update_metadata" do
    let(:candidate) { create_server(version: "16") }

    before do
      strand.update(label: "update_metadata")
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
    end

    it "creates new timeline and updates candidate server metadata and hops to recycle_representative_server" do
      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).with(location_id: location_id).and_call_original

      expect { nx.update_metadata }.to hop("wait_upgrade_candidate")

      candidate.reload
      expect(candidate.version).to eq("17")
      expect(candidate.timeline_access).to eq("push")
      expect(candidate.refresh_walg_credentials_set?).to be true
      expect(candidate.configure_set?).to be true
      expect(candidate.restart_set?).to be true
    end
  end

  describe "#wait_upgrade_candidate" do
    before do
      strand.update(label: "wait_upgrade_candidate")
    end

    it "hops to recycle_representative_server when candidate is ready" do
      candidate = create_server(version: "16")
      candidate.strand.update(label: "wait")
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      expect { nx.wait_upgrade_candidate }.to hop("recycle_representative_server")
    end

    it "waits when candidate is waiting for restart" do
      candidate = create_server(version: "16")
      candidate.incr_restart
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      expect { nx.wait_upgrade_candidate }.to nap(5)
    end

    it "waits when candidate is not ready" do
      candidate = create_server(version: "16")
      candidate.strand.update(label: "configure")
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      expect { nx.wait_upgrade_candidate }.to nap(5)
    end
  end

  describe "#upgrade_failed" do
    let(:candidate) { create_server(version: "16") }
    let(:primary) { create_server(representative: true) }
    let(:sshable) { create_mock_sshable_for_vm(candidate.vm) }

    before do
      strand.update(label: "upgrade_failed")
      primary.strand.update(label: "wait_in_fence")
      allow(nx).to receive(:upgrade_candidate).and_return(candidate)
      allow(postgres_resource).to receive(:representative_server).and_return(primary)
    end

    it "logs failure, raises a page and destroys candidate server" do
      expect(sshable).to receive(:cmd).with("sudo journalctl -u upgrade_postgres").and_return("log line 1\nlog line 2")
      expect(Clog).to receive(:emit).with("Postgres resource upgrade failed").and_yield.twice
      expect(Prog::PageNexus).to receive(:assemble)
      expect(primary).to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)

      expect(candidate.reload.destroy_set?).to be true
    end

    it "unfences primary if it is fenced" do
      allow(sshable).to receive(:cmd).and_return("")
      allow(Clog).to receive(:emit)
      expect(primary).to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "does not unfence if primary is not fenced" do
      primary.strand.update(label: "wait")
      allow(sshable).to receive(:cmd).and_return("")
      allow(Clog).to receive(:emit)
      expect(primary).not_to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "handles case when candidate is nil" do
      allow(nx).to receive(:upgrade_candidate).and_return(nil)
      allow(primary).to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end

    it "handles case when candidate is not nil but destroy_set? is true" do
      candidate.incr_destroy
      allow(primary).to receive(:incr_unfence)

      expect { nx.upgrade_failed }.to nap(6 * 60 * 60)
    end
  end

  describe "#prune_servers" do
    before do
      strand.update(label: "prune_servers")
    end

    it "destroys extra servers but keeps those that don't need recycling and match current version" do
      # Use instance_doubles for this complex test as needs_recycling? depends on VM state
      representative = instance_double(PostgresServer, representative_at: "yesterday", needs_recycling?: false, created_at: 1, strand: instance_double(Strand, label: "wait"), version: "17")
      recycling_server = instance_double(PostgresServer, representative_at: nil, needs_recycling?: true, created_at: 5, strand: instance_double(Strand, label: "wait"), version: "17")
      unavailable_server = instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 4, strand: instance_double(Strand, label: "unavailable"), version: "17")
      keep_server = instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 3, strand: instance_double(Strand, label: "wait"), version: "17")
      extra_server = instance_double(PostgresServer, representative_at: nil, needs_recycling?: false, created_at: 2, strand: instance_double(Strand, label: "wait"), version: "17")

      allow(postgres_resource).to receive_messages(servers: [representative, recycling_server, unavailable_server, keep_server, extra_server], representative_server: representative, target_standby_count: 1)

      expect(recycling_server).to receive(:incr_destroy)
      expect(unavailable_server).to receive(:incr_destroy)
      expect(extra_server).to receive(:incr_destroy)

      expect(representative).to receive(:incr_configure)
      expect(keep_server).to receive(:incr_configure)
      allow(postgres_resource).to receive(:incr_update_billing_records)

      expect { nx.prune_servers }.to exit
    end

    it "destroys servers with older versions" do
      old_server = create_server(version: "16")
      new_server = create_server(version: "17", representative: true)

      expect { nx.prune_servers }.to exit

      expect(old_server.reload.destroy_set?).to be true
      expect(new_server.reload.configure_set?).to be true
    end
  end

  describe "#upgrade_candidate" do
    it "returns the upgrade candidate server" do
      candidate = create_server(version: "16")
      allow(postgres_resource).to receive(:upgrade_candidate_server).and_return(candidate)
      expect(nx.upgrade_candidate).to eq(candidate)
    end
  end
end
