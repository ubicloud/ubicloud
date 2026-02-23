# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    pr = described_class.create(
      name: "gcp-pg-resource",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id: location.id,
      project_id: project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    )
    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  }

  let(:project) { Project.create(name: "gcp-pg-project") }

  let(:location) {
    Location.create(
      name: "us-central1",
      display_name: "GCP us-central1",
      ui_name: "GCP US Central 1",
      visible: false,
      provider: "gcp"
    )
  }

  def create_gcp_vm_with_nic(name, zone_suffix:)
    @nic_counter ||= 0
    @nic_counter += 1
    subnet = PrivateSubnet.create(name: "#{name}-subnet", location_id: location.id,
      project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.#{@nic_counter}.0/26", state: "active") { it.id = SecureRandom.uuid }
    nic_id = SecureRandom.uuid
    nic = Nic.create_with_id(nic_id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb::#{@nic_counter}",
      private_ipv4: "10.0.#{@nic_counter}.1",
      name: "#{name}-nic",
      private_subnet_id: subnet.id,
      state: "active")
    Strand.create_with_id(nic, prog: "Vnet::Gcp::NicNexus", label: "wait",
      stack: [{"gcp_zone_suffix" => zone_suffix}])

    vm = create_vm(
      project_id: project.id,
      location_id: location.id,
      name:,
      memory_gib: 8
    )
    nic.update(vm_id: vm.id)
    vm
  end

  context "with GCP provider" do
    describe "#upgrade_candidate_server" do
      it "returns the most recent non-representative server" do
        timeline = PostgresTimeline.create(location_id: location.id)
        vm = create_vm(
          project_id: project.id,
          location_id: location.id,
          name: "gcp-pg-vm",
          memory_gib: 8
        )

        server = PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )

        expect(postgres_resource.reload).to receive(:servers).and_return([server])

        expect(postgres_resource.upgrade_candidate_server).to eq(server)
      end

      it "returns nil when no eligible servers exist" do
        expect(postgres_resource.upgrade_candidate_server).to be_nil
      end

      it "excludes representative servers" do
        timeline = PostgresTimeline.create(location_id: location.id)
        vm = create_vm(
          project_id: project.id,
          location_id: location.id,
          name: "gcp-pg-vm",
          memory_gib: 8
        )

        server = PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )
        DB[:postgres_server].where(id: server.id).update(is_representative: true)
        server.reload

        expect(postgres_resource.reload).to receive(:servers).and_return([server])

        expect(postgres_resource.upgrade_candidate_server).to be_nil
      end
    end

    describe "#new_server_exclusion_filters" do
      let(:timeline) { PostgresTimeline.create(location_id: location.id) }

      it "returns empty exclusion filters when there are no servers" do
        filters = postgres_resource.new_server_exclusion_filters
        expect(filters).to be_a(PostgresResource::ServerExclusionFilters)
        expect(filters.exclude_host_ids).to eq([])
        expect(filters.exclude_data_centers).to eq([])
        expect(filters.exclude_availability_zones).to eq([])
        expect(filters.availability_zone).to be_nil
      end

      it "excludes zones where existing servers are running" do
        vm1 = create_gcp_vm_with_nic("gcp-pg-vm-1", zone_suffix: "a")

        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm1.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )

        filters = postgres_resource.reload.new_server_exclusion_filters
        expect(filters.exclude_availability_zones).to eq(["a"])
        expect(filters.availability_zone).to be_nil
      end

      it "excludes multiple zones from different servers" do
        vm1 = create_gcp_vm_with_nic("gcp-pg-vm-1", zone_suffix: "a")
        vm2 = create_gcp_vm_with_nic("gcp-pg-vm-2", zone_suffix: "b")

        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm1.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )
        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm2.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )

        filters = postgres_resource.reload.new_server_exclusion_filters
        expect(filters.exclude_availability_zones).to contain_exactly("a", "b")
      end

      it "deduplicates zones when multiple servers share the same zone" do
        vm1 = create_gcp_vm_with_nic("gcp-pg-vm-1", zone_suffix: "a")
        vm2 = create_gcp_vm_with_nic("gcp-pg-vm-2", zone_suffix: "a")

        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm1.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )
        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm2.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )

        filters = postgres_resource.reload.new_server_exclusion_filters
        expect(filters.exclude_availability_zones).to eq(["a"])
      end
    end
  end
end
