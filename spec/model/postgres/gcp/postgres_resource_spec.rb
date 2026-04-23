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
      target_storage_size_gib: 64,
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
      provider: "gcp",
    )
  }

  def create_gcp_vm_with_nic(name, zone_suffix:)
    @nic_counter ||= 0
    @nic_counter += 1
    subnet = PrivateSubnet.create(name: "#{name}-subnet", location_id: location.id,
      project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.#{@nic_counter}.0/26", state: "active")
    nic = Nic.create(
      private_ipv6: "fd10:9b0b:6b4b:8fbb::#{@nic_counter}",
      private_ipv4: "10.0.#{@nic_counter}.1",
      name: "#{name}-nic",
      private_subnet_id: subnet.id,
      state: "active",
    )

    vm = create_vm(
      project_id: project.id,
      location_id: location.id,
      name:,
      memory_gib: 8,
    )
    location_az = LocationAz.first(location_id: location.id, az: zone_suffix) ||
      LocationAz.create(location_id: location.id, az: zone_suffix)
    VmGcpResource.create_with_id(vm, location_az_id: location_az.id)
    nic.update(vm_id: vm.id)
    vm
  end

  context "with GCP provider" do
    describe "#upgrade_candidate_server" do
      before { PgGceImage.dataset.destroy }

      let(:gce_image_name) { "postgres-ubuntu-2204-x64-20260223" }
      let(:gce_image_path) { "projects/test-pg-project/global/images/#{gce_image_name}" }

      def create_gcp_pg_server(boot_image: gce_image_path, server_version: "17")
        timeline = PostgresTimeline.create(location_id: location.id)
        vm = create_vm(
          project_id: project.id,
          location_id: location.id,
          name: "gcp-pg-vm-#{SecureRandom.hex(3)}",
          memory_gib: 8,
          boot_image:,
        )
        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm.id,
          synchronization_status: "ready", timeline_access: "push", version: server_version,
        )
      end

      it "returns the most recent non-representative server whose image has the target version" do
        PgGceImage.create(gce_image_name:, arch: "x64", pg_versions: ["16", "17", "18"])
        server = create_gcp_pg_server

        expect(postgres_resource.reload.upgrade_candidate_server).to eq(server)
      end

      it "returns nil when no eligible servers exist" do
        expect(postgres_resource.upgrade_candidate_server).to be_nil
      end

      it "excludes representative servers" do
        PgGceImage.create(gce_image_name:, arch: "x64", pg_versions: ["16", "17", "18"])
        server = create_gcp_pg_server
        server.update(is_representative: true)

        expect(postgres_resource.reload.upgrade_candidate_server).to be_nil
      end

      it "skips candidates whose boot image pg_versions lacks the target version" do
        PgGceImage.create(gce_image_name:, arch: "x64", pg_versions: ["16"])
        create_gcp_pg_server

        expect(postgres_resource.reload.upgrade_candidate_server).to be_nil
      end

      it "skips candidates whose boot image is not a known pg_gce_image" do
        PgGceImage.create(gce_image_name: "other-image", arch: "x64", pg_versions: ["16", "17", "18"])
        create_gcp_pg_server

        expect(postgres_resource.reload.upgrade_candidate_server).to be_nil
      end

      it "prefers the newest eligible server over an older eligible one" do
        PgGceImage.create(gce_image_name:, arch: "x64", pg_versions: ["16", "17", "18"])
        old_server = create_gcp_pg_server
        old_server.update(created_at: Time.now - 3600)
        new_server = create_gcp_pg_server

        expect(postgres_resource.reload.upgrade_candidate_server).to eq(new_server)
      end
    end

    describe "#boot_image" do
      before do
        PgGceImage.dataset.destroy
        allow(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
      end

      it "delegates to the location's pg_gce_image for a supported pg_version" do
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
          arch: "arm64",
          pg_versions: ["16", "17", "18"],
        )

        expect(postgres_resource.boot_image("17", "arm64")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-arm64-20260218",
        )
      end

      it "raises when no image supports the requested pg_version (non-upgrade path)" do
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
          arch: "arm64",
          pg_versions: ["16"],
        )

        expect {
          postgres_resource.boot_image("17", "arm64")
        }.to raise_error(RuntimeError, /No GCE image found for arch arm64 and pg_version 17/)
      end

      it "threads the resource target_version so upgrade standbys pick a dual-version image" do
        postgres_resource.update(target_version: "18")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260223",
          arch: "x64",
          pg_versions: ["16", "17"],
        )
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260501",
          arch: "x64",
          pg_versions: ["17", "18"],
        )

        # Standbys are provisioned at the current version (17) while an
        # upgrade to 18 is in progress. Selecting the dual-version image
        # ensures gcp_upgrade_candidate_server's `pg_versions @> [18]`
        # filter still accepts the new standby, avoiding an upgrade wedge.
        expect(postgres_resource.reload.boot_image("17", "x64")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260501",
        )
      end

      it "fails fast when no dual-version image exists for the upgrade" do
        postgres_resource.update(target_version: "18")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260223",
          arch: "x64",
          pg_versions: ["16", "17"],
        )

        expect {
          postgres_resource.reload.boot_image("17", "x64")
        }.to raise_error(
          RuntimeError,
          /No dual-version GCE image found for arch x64 covering pg_version=17 \+ target_version=18/,
        )
      end

      it "picks the image whose pg_versions array contains the requested version" do
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-arm64-20260218",
          arch: "arm64",
          pg_versions: ["16", "17", "18"],
        )
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2404-arm64-20270101",
          arch: "arm64",
          pg_versions: ["19"],
        )

        expect(postgres_resource.boot_image("17", "arm64")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-arm64-20260218",
        )
        # Set target_version past the CHECK constraint to exercise the
        # non-upgrade lookup for a version above the schema-allowed range.
        # The CHECK only fires on save, so an in-memory assignment is safe.
        postgres_resource.target_version = "19"
        expect(postgres_resource.boot_image("19", "arm64")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-arm64-20270101",
        )
      end
    end

    describe "#lockout_mechanisms" do
      it "returns pg_stop and hba" do
        expect(postgres_resource.lockout_mechanisms).to eq(["pg_stop", "hba"])
      end
    end

    describe "#new_server_exclusion_filters" do
      let(:timeline) { PostgresTimeline.create(location_id: location.id) }

      def create_server(vm, is_representative: false)
        PostgresServer.create(
          timeline:, resource: postgres_resource, vm_id: vm.id,
          synchronization_status: "ready", timeline_access: "push", version: "17",
          is_representative:,
        )
      end

      context "when use_different_az_set? is false" do
        it "pins availability_zone to the representative server's zone" do
          vm1 = create_gcp_vm_with_nic("gcp-pg-vm-1", zone_suffix: "a")
          vm2 = create_gcp_vm_with_nic("gcp-pg-vm-2", zone_suffix: "b")
          create_server(vm1, is_representative: true)
          create_server(vm2)

          filters = postgres_resource.reload.new_server_exclusion_filters
          expect(filters.exclude_availability_zones).to eq([])
          expect(filters.availability_zone).to eq("a")
        end
      end

      context "when use_different_az_set? is true" do
        before { postgres_resource.incr_use_different_az }

        def make_active_server(name, zone_suffix:, is_representative: false)
          server = create_server(create_gcp_vm_with_nic(name, zone_suffix:), is_representative:)
          allow(server).to receive_messages(needs_recycling?: false, destroy_set?: false)
          server
        end

        it "excludes zones of active servers" do
          ps1 = make_active_server("gcp-pg-vm-1", zone_suffix: "a", is_representative: true)
          ps2 = make_active_server("gcp-pg-vm-2", zone_suffix: "b")
          expect(postgres_resource).to receive(:servers).and_return([ps1, ps2])

          filters = postgres_resource.new_server_exclusion_filters
          expect(filters.exclude_availability_zones).to contain_exactly("a", "b")
          expect(filters.availability_zone).to be_nil
        end

        it "deduplicates zones when multiple servers share the same zone" do
          ps1 = make_active_server("gcp-pg-vm-1", zone_suffix: "a", is_representative: true)
          ps2 = make_active_server("gcp-pg-vm-2", zone_suffix: "a")
          expect(postgres_resource).to receive(:servers).and_return([ps1, ps2])

          filters = postgres_resource.new_server_exclusion_filters
          expect(filters.exclude_availability_zones).to eq(["a"])
        end

        it "does not exclude AZ of a server being recycled" do
          ps1 = make_active_server("gcp-pg-vm-1", zone_suffix: "a", is_representative: true)
          ps2 = make_active_server("gcp-pg-vm-2", zone_suffix: "b")
          expect(ps2).to receive(:needs_recycling?).and_return(true)
          expect(postgres_resource).to receive(:servers).and_return([ps1, ps2])

          filters = postgres_resource.new_server_exclusion_filters
          expect(filters.exclude_availability_zones).to eq(["a"])
        end

        it "does not exclude AZ of a server being destroyed" do
          ps1 = make_active_server("gcp-pg-vm-1", zone_suffix: "a", is_representative: true)
          ps2 = make_active_server("gcp-pg-vm-2", zone_suffix: "b")
          expect(ps2).to receive(:destroy_set?).and_return(true)
          expect(postgres_resource).to receive(:servers).and_return([ps1, ps2])

          filters = postgres_resource.new_server_exclusion_filters
          expect(filters.exclude_availability_zones).to eq(["a"])
        end
      end
    end
  end
end
