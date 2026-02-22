# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project_id) { Project.create(name: "test").id }

  let(:mi) {
    described_class.create(
      name: "test-image",
      description: "test machine image",
      project_id:,
      location_id: Location::HETZNER_FSN1_ID,
      state: "available",
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com",
      size_gib: 20
    )
  }

  it "has a valid UBID" do
    expect(mi.ubid).to start_with("m1")
  end

  it "has a path" do
    expect(mi.path).to eq("/location/eu-central-h1/machine-image/test-image")
  end

  it "has a display_location" do
    expect(mi.display_location).to eq("eu-central-h1")
  end

  it "has an arch that defaults to x64" do
    expect(mi.arch).to eq("x64")
  end

  it "has project association" do
    expect(mi.project).to be_a(Project)
    expect(mi.project.id).to eq(project_id)
  end

  it "has location association" do
    expect(mi.location).to be_a(Location)
  end

  it "is listed in project.machine_images" do
    expect(mi.project.machine_images).to include(mi)
  end

  describe ".for_project" do
    let(:other_project_id) { Project.create(name: "other").id }

    let(:other_private_mi) {
      described_class.create(
        name: "other-private", project_id: other_project_id,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )
    }

    let(:other_public_mi) {
      described_class.create(
        name: "other-public", project_id: other_project_id,
        location_id: Location::HETZNER_FSN1_ID, state: "available", visible: true,
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )
    }

    it "returns images owned by the project" do
      mi # ensure created
      other_private_mi
      result = described_class.for_project(project_id).all
      expect(result).to include(mi)
      expect(result).not_to include(other_private_mi)
    end

    it "returns public images from other projects" do
      mi
      other_public_mi
      result = described_class.for_project(project_id).all
      expect(result).to include(mi)
      expect(result).to include(other_public_mi)
    end

    it "does not return private images from other projects" do
      other_private_mi
      result = described_class.for_project(project_id).all
      expect(result).not_to include(other_private_mi)
    end

    it "excludes decommissioned images" do
      mi
      mi.update(state: "decommissioned")
      result = described_class.for_project(project_id).all
      expect(result).not_to include(mi)
    end

    it "excludes decommissioned public images from other projects" do
      other_public_mi
      other_public_mi.update(state: "decommissioned")
      result = described_class.for_project(project_id).all
      expect(result).not_to include(other_public_mi)
    end
  end

  it "returns encrypted?" do
    expect(mi.encrypted?).to be true
    mi.update(encrypted: false)
    expect(mi.reload.encrypted?).to be false
  end

  it "returns archive_params" do
    params = mi.archive_params
    expect(params["type"]).to eq("archive")
    expect(params["archive_bucket"]).to eq("test-bucket")
    expect(params["archive_prefix"]).to eq("images/test/")
    expect(params["archive_endpoint"]).to eq("https://r2.example.com")
    expect(params["compression"]).to eq("zstd")
    expect(params["encrypted"]).to be true
  end

  describe ".register_distro_image" do
    let(:vm_host) { create_vm_host }

    before do
      allow(Config).to receive_messages(
        machine_image_archive_bucket: "distro-bucket",
        machine_image_archive_endpoint: "https://r2.example.com"
      )
    end

    it "creates a private unencrypted machine image and strand" do
      result = described_class.register_distro_image(
        project_id:,
        location_id: Location::HETZNER_FSN1_ID,
        name: "ubuntu-noble",
        url: "https://cloud-images.ubuntu.com/noble/release/image.img",
        sha256: "abc123",
        version: "20250502.1",
        vm_host_id: vm_host.id
      )

      expect(result).to be_a(described_class)
      expect(result.name).to eq("ubuntu-noble")
      expect(result.version).to eq("20250502.1")
      expect(result.visible).to be false
      expect(result.encrypted).to be false
      expect(result.state).to eq("creating")
      expect(result.s3_bucket).to eq("distro-bucket")
      expect(result.s3_prefix).to include("public/ubuntu-noble/20250502.1/")
      expect(result.s3_prefix).to include(result.ubid)

      strand = Strand[result.id]
      expect(strand).not_to be_nil
      expect(strand.prog).to eq("MachineImage::RegisterDistroImage")
      expect(strand.label).to eq("start")
      expect(strand.stack.first["vm_host_id"]).to eq(vm_host.id)
      expect(strand.stack.first["url"]).to include("ubuntu")
      expect(strand.stack.first["sha256"]).to eq("abc123")
    end
  end

  describe "#before_destroy" do
    it "nulls out machine_image_id on referencing volumes" do
      vm_host = create_vm_host
      vm = create_vm(vm_host_id: vm_host.id, project_id:)
      sd = StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", available_storage_gib: 200, total_storage_gib: 200)
      vbb = VhostBlockBackend.create(version: "v0.4.0", allocation_weight: 100, vm_host_id: vm_host.id)
      vol = VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0,
        machine_image_id: mi.id, storage_device_id: sd.id,
        vhost_block_backend_id: vbb.id, vring_workers: 1
      )

      mi.destroy

      expect(described_class[mi.id]).to be_nil
      expect(vol.reload.machine_image_id).to be_nil
    end

    it "finalizes active billing records" do
      br = BillingRecord.create(
        project_id:,
        resource_id: mi.id,
        resource_name: mi.name,
        billing_rate_id: BillingRate.from_resource_properties("VmCores", "standard", "hetzner-fsn1")["id"],
        amount: 1
      )

      mi.destroy

      expect(BillingRecord[br.id].span.unbounded_end?).to be false
    end

    it "destroys the KEK for encrypted images" do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: "dGVzdGtleQ==",
        init_vector: "dGVzdGl2",
        auth_data: "test"
      )
      mi.update(encrypted: true, key_encryption_key_1_id: kek.id)

      mi.destroy

      expect(StorageKeyEncryptionKey[kek.id]).to be_nil
    end

    it "handles unencrypted images without KEK" do
      mi.update(encrypted: false, key_encryption_key_1_id: nil)

      mi.destroy

      expect(described_class[mi.id]).to be_nil
    end
  end

  describe "versioning" do
    it "defaults active to true" do
      expect(mi.active?).to be true
    end

    it "defaults version to v1" do
      expect(mi.version).to eq("v1")
    end

    it "has a version_path" do
      expect(mi.version_path).to eq("/location/eu-central-h1/machine-image/#{mi.ubid}")
    end

    it "returns versions for the same name/project/location" do
      v2 = described_class.create(
        name: "test-image", version: "v2", project_id:,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 20
      )

      expect(mi.versions).to include(mi, v2)
    end

    it "excludes decommissioned versions" do
      v2 = described_class.create(
        name: "test-image", version: "v2", project_id:,
        location_id: Location::HETZNER_FSN1_ID, state: "decommissioned",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 20
      )

      expect(mi.versions).to include(mi)
      expect(mi.versions).not_to include(v2)
    end

    it "sets active version and deactivates others" do
      mi.update(active: true)
      v2 = described_class.create(
        name: "test-image", version: "v2", active: false, project_id:,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 20
      )

      v2.set_active!

      expect(mi.reload.active?).to be false
      expect(v2.reload.active?).to be true
    end

    it "finds active version by name" do
      mi.update(active: false)
      v2 = described_class.create(
        name: "test-image", version: "v2", active: true, project_id:,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 20
      )

      result = described_class.active_version(project_id:, location_id: Location::HETZNER_FSN1_ID, name: "test-image")
      expect(result).to eq(v2)
    end

    it "returns active_versions dataset" do
      mi # ensure created before query
      inactive = described_class.create(
        name: "other-image", version: "v1", active: false, project_id:,
        location_id: Location::HETZNER_FSN1_ID, state: "available",
        s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com", size_gib: 10
      )

      result = described_class.where(project_id:).active_versions.all
      expect(result.map(&:id)).to include(mi.id)
      expect(result.map(&:id)).not_to include(inactive.id)
    end
  end

  describe ".register_distro_image" do
    it "deactivates old versions when registering a new one" do
      allow(Config).to receive_messages(
        machine_image_archive_bucket: "distro-bucket",
        machine_image_archive_endpoint: "https://r2.example.com"
      )
      vm_host = create_vm_host

      v1 = described_class.register_distro_image(
        project_id:, location_id: Location::HETZNER_FSN1_ID,
        name: "ubuntu-noble", url: "https://example.com/v1.img",
        sha256: "abc", version: "v1", vm_host_id: vm_host.id
      )
      expect(v1.active?).to be true

      v2 = described_class.register_distro_image(
        project_id:, location_id: Location::HETZNER_FSN1_ID,
        name: "ubuntu-noble", url: "https://example.com/v2.img",
        sha256: "def", version: "v2", vm_host_id: vm_host.id
      )

      expect(v1.reload.active?).to be false
      expect(v2.active?).to be true
    end
  end

  describe "state predicates" do
    it "returns true for available?" do
      expect(mi.available?).to be true
      expect(mi.creating?).to be false
    end

    it "returns true for creating?" do
      mi.update(state: "creating")
      expect(mi.creating?).to be true
      expect(mi.available?).to be false
    end

    it "returns true for decommissioned?" do
      mi.update(state: "decommissioned")
      expect(mi.decommissioned?).to be true
    end

    it "returns true for verifying?" do
      mi.update(state: "verifying")
      expect(mi.verifying?).to be true
    end

    it "returns true for destroying?" do
      mi.update(state: "destroying")
      expect(mi.destroying?).to be true
    end
  end
end
