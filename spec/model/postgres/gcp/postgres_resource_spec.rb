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

  context "with GCP provider" do
    describe "#upgrade_candidate_server" do
      it "returns the most recent non-representative server with a valid boot image" do
        timeline = PostgresTimeline.create(location_id: location.id)
        vm = create_vm(
          project_id: project.id,
          location_id: location.id,
          name: "gcp-pg-vm",
          memory_gib: 8
        )

        boot_image = instance_double(BootImage, version: "20260101")
        boot_vol = instance_double(VmStorageVolume, boot: true, boot_image:)

        server = PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm.id,
          synchronization_status: "ready", timeline_access: "push", version: "17"
        )

        expect(postgres_resource.reload).to receive(:servers).and_return([server])
        expect(server.vm).to receive(:vm_storage_volumes).and_return([boot_vol])

        expect(postgres_resource.upgrade_candidate_server).to eq(server)
      end

      it "returns nil when no eligible servers exist" do
        expect(postgres_resource.upgrade_candidate_server).to be_nil
      end
    end

    describe "#new_server_exclusion_filters" do
      it "returns empty exclusion filters" do
        filters = postgres_resource.new_server_exclusion_filters
        expect(filters).to be_a(PostgresResource::ServerExclusionFilters)
        expect(filters.exclude_host_ids).to eq([])
        expect(filters.exclude_data_centers).to eq([])
        expect(filters.exclude_availability_zones).to eq([])
        expect(filters.availability_zone).to be_nil
      end
    end
  end
end
