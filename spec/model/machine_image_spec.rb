# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    described_class.create(
      name: "test-image",
      project_id: project.id,
      location_id: location.id,
      arch: "arm64"
    )
  }

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 when no versions exist for today" do
      today = Date.today.strftime("%Y%m%d")
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: "00000000-0000-0000-0000-000000000000"))
      expect(result).to eq("#{today}-1")
    end

    it "increments N for same-day versions" do
      today = Date.today.strftime("%Y%m%d")
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "#{today}-1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "#{today}-2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{today}-3")

      v1.destroy
      v2.destroy
    end

    it "does not count versions from other days" do
      today = Date.today.strftime("%Y%m%d")
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "20240101-1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{today}-1")

      v.destroy
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "returns /location/LOC/machine-image/UBID" do
      expect(mi.path).to eq("/location/#{location.display_name}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    it "returns version with most recent activated_at" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now - 3600
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )

      # Non-eager-loaded path
      expect(mi.reload.active_version.id).to eq(v2.id)

      # Eager-loaded path
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v2.id)

      v1.destroy
      v2.destroy
    end

    it "returns nil when no versions have activated_at" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      expect(mi.reload.active_version).to be_nil

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version).to be_nil

      v.destroy
    end
  end

  describe "#latest_available_version" do
    it "returns latest available version by created_at" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      expect(mi.reload.latest_available_version.id).to eq(v1.id)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v1.id)

      v1.destroy
      v2.destroy
    end

    it "returns nil when no available versions exist" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      expect(mi.reload.latest_available_version).to be_nil

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version).to be_nil

      v.destroy
    end
  end

  describe "#available_versions" do
    it "returns all available versions ordered by created_at desc" do
      t = Time.now
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t - 20
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "failed",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t - 10
      )
      v3 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t
      )

      result = mi.reload.available_versions
      expect(result.map(&:id)).to eq([v3.id, v1.id])

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.available_versions.map(&:id)).to eq([v3.id, v1.id])

      v1.destroy
      v2.destroy
      v3.destroy
    end

    it "returns empty array when no available versions exist" do
      expect(mi.available_versions).to eq([])
    end
  end

  describe "associations" do
    it "has versions ordered by created_at desc" do
      t = Time.now
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t - 10
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t
      )

      expect(mi.reload.versions.map(&:id)).to eq([v2.id, v1.id])

      v1.destroy
      v2.destroy
    end

    it "belongs to project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to location" do
      expect(mi.location.id).to eq(location.id)
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(mi.ubid).to start_with("m1")
    end
  end

  describe "ObjectTag::Cleanup" do
    it "removes referencing access control entries and object tag memberships" do
      account = Account.create(email: "test-mi@example.com")
      proj = account.create_project_with_default_policy("proj-mi", default_policy: false)
      tag = ObjectTag.create(project_id: proj.id, name: "t")
      tag.add_member(mi.id)
      mi.update(project_id: proj.id)
      ace = AccessControlEntry.create(project_id: proj.id, subject_id: account.id, object_id: mi.id)

      mi.destroy
      expect(tag.member_ids).to be_empty
      expect(ace).not_to be_exists
    end
  end

  describe "#before_destroy" do
    it "destroys all versions" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      mi.destroy
      expect(MachineImageVersion[v.id]).to be_nil
    end
  end

  describe "dataset_module" do
    it "filters by project with for_project" do
      other_project = Project.create(name: "other")
      other_mi = described_class.create(
        name: "other-image", project_id: other_project.id,
        location_id: location.id
      )

      mi # ensure mi is created before querying
      result = described_class.for_project(project.id).all
      expect(result.map(&:id)).to include(mi.id)
      expect(result.map(&:id)).not_to include(other_mi.id)

      other_mi.destroy
    end
  end
end
