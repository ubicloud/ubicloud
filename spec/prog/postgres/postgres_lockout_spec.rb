# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresLockout do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource }
  let(:postgres_timeline) { create_postgres_timeline }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:resource) { postgres_resource }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  def create_postgres_timeline
    tl_id = PostgresTimeline.generate_uuid
    tl = PostgresTimeline.create_with_id(tl_id,
      location_id:,
      access_key: "dummy-access-key",
      secret_key: "dummy-secret-key")
    Strand.create_with_id(tl_id, prog: "Postgres::PostgresTimelineNexus", label: "wait")
    tl
  end

  def create_postgres_resource(location_id: self.location_id, target_version: "16")
    pr = PostgresResource.create(
      name: "pg-test-#{SecureRandom.hex(4)}",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version:,
      location_id:,
      project_id: project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2",
      server_cert: "server_cert",
      server_cert_key: "server_cert_key"
    )
    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  end

  def create_read_replica_resource(parent: postgres_resource, with_strand: false)
    pr = PostgresResource.create(
      name: "pg-replica-#{SecureRandom.hex(4)}",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "16",
      location_id:,
      project_id: project.id,
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      parent_id: parent.id
    )
    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait") if with_strand
    pr
  end

  def create_postgres_server(resource:, timeline: nil, timeline_access: "push", representative: true, version: "16")
    timeline ||= create_postgres_timeline
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "pg-vm-#{SecureRandom.hex(4)}", private_subnet_id: private_subnet.id,
      location_id:, unix_user: "ubi"
    ).subject
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1)
    server_id = PostgresServer.generate_uuid
    server = PostgresServer.create_with_id(server_id,
      timeline:,
      resource_id: resource.id,
      vm_id: vm.id,
      representative_at: representative ? Time.now : nil,
      synchronization_status: "ready",
      timeline_access:,
      version:)
    Strand.create_with_id(server_id, prog: "Postgres::PostgresServerNexus", label: "start")
    server
  end

  def create_standby_nexus(prime_sshable: false)
    server
    standby_record = create_postgres_server(
      resource: postgres_resource, timeline: postgres_timeline,
      representative: false, timeline_access: "fetch", version: "16"
    )
    standby_nx = described_class.new(standby_record.strand)
    ps = standby_nx.postgres_server
    resource = ps.resource
    rep = resource.representative_server
    if prime_sshable
      rep.vm.associations[:sshable] = rep.vm.sshable
      [standby_nx, rep.vm.sshable]
    else
      standby_nx
    end
  end

  describe "#start" do
    it "uses the appropriate lockout mechanism" do
      ["pg_stop", "hba", "host_routing"].each do |mechanism|
        refresh_frame(nx, new_frame: {"mechanism" => mechanism})
        expect(nx).to receive("lockout_with_#{mechanism}").and_return(true)
        expect { nx.start }.to exit({"msg" => "lockout_succeeded"})
      end
    end

    it "returns false for failed lockout" do
      refresh_frame(nx, new_frame: {"mechanism" => "pg_stop"})
      allow(nx).to receive(:lockout_with_pg_stop).and_return(false)
      expect { nx.start }.to exit({"msg" => "lockout_failed"})
    end

    it "returns false for unknown mechanism" do
      refresh_frame(nx, new_frame: {"mechanism" => "unknown_mechanism"})
      expect { nx.start }.to exit({"msg" => "lockout_failed"})
    end
  end

  describe "#lockout_with_pg_stop" do
    it "stops postgres and returns true on success" do
      expect(sshable).to receive(:_cmd).with(
        "sudo pg_ctlcluster #{server.version} main stop -m immediate",
        timeout: 2
      ).and_return(true)
      expect(Clog).to receive(:emit).with("Fenced unresponsive primary by stopping PostgreSQL").and_yield
      expect(nx.lockout_with_pg_stop).to be true
    end

    it "returns false on failure" do
      expect(sshable).to receive(:_cmd).with(
        "sudo pg_ctlcluster #{server.version} main stop -m immediate",
        timeout: 2
      ).twice.and_raise(Sshable::SshError.new("", "", "", "", ""))
      expect(nx.lockout_with_pg_stop).to be false
    end
  end

  describe "#lockout_with_hba" do
    it "applies lockout pg_hba.conf and returns true on success" do
      expect(sshable).to receive(:_cmd).with(
        "sudo postgres/bin/lockout-hba #{server.version}",
        timeout: 2
      ).and_return(true)
      expect(Clog).to receive(:emit).with("Fenced unresponsive primary by applying lockout pg_hba.conf").and_yield
      expect(nx.lockout_with_hba).to be true
    end

    it "returns false on failure" do
      expect(sshable).to receive(:_cmd).with(
        "sudo postgres/bin/lockout-hba #{server.version}",
        timeout: 2
      ).twice.and_raise(Sshable::SshError.new("", "", "", "", ""))
      expect(nx.lockout_with_hba).to be false
    end
  end

  describe "#lockout_with_host_routing" do
    let(:vm_host) { create_vm_host(location_id:) }
    let(:vm_host_sshable) { vm_host.sshable }

    before do
      allow(server.vm).to receive_messages(ip4: "10.20.30.40", ephemeral_net6: "fd00:1234:5678:9abc::1/64")
      server.vm.update(vm_host_id: vm_host.id)
      allow(server.vm).to receive(:vm_host).and_return(vm_host)
    end

    it "applies lockout host routing and returns true on success" do
      expect(vm_host_sshable).to receive(:_cmd).with(
        "sudo ip route del #{server.vm.ip4} dev vmhost#{server.vm.inhost_name}",
        timeout: 1
      ).and_return(true)
      expect(vm_host_sshable).to receive(:_cmd).with(
        "sudo ip -6 route del #{server.vm.ephemeral_net6} dev vetho#{server.vm.inhost_name}",
        timeout: 1
      ).and_return(true)
      expect(Clog).to receive(:emit).with("Fenced unresponsive primary by blocking host routing").and_yield
      expect(nx.lockout_with_host_routing).to be true
    end

    it "returns false on failure" do
      expect(vm_host_sshable).to receive(:_cmd).with(
        "sudo ip route del #{server.vm.ip4} dev vmhost#{server.vm.inhost_name}",
        timeout: 1
      ).twice.and_raise(Sshable::SshError.new("", "", "", "", ""))
      expect(nx.lockout_with_host_routing).to be false
    end

    it "returns false if vm_host is nil" do
      server.vm.update(vm_host_id: nil)
      allow(server.vm).to receive(:vm_host).and_return(nil)
      expect(nx.lockout_with_host_routing).to be false
    end
  end
end
