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
      result = described_class.next_auto_version(MachineImageVersion.dataset)
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")
    end

    it "increments N for same day" do
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
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "20200101-1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")

      v.destroy
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "returns the correct path" do
      expect(mi.path).to eq("/location/#{location.display_name}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    it "returns version with most recent activated_at (non-eager)" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now - 100
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )

      mi_fresh = described_class[mi.id]
      expect(mi_fresh.active_version.id).to eq(v2.id)

      v1.destroy
      v2.destroy
    end

    it "returns version with most recent activated_at (eager-loaded)" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now - 100
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )

      mi_eager = described_class.eager(:versions).where(id: mi.id).first
      expect(mi_eager.active_version.id).to eq(v2.id)

      v1.destroy
      v2.destroy
    end

    it "returns nil when no versions are activated" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      expect(described_class[mi.id].active_version).to be_nil

      v.destroy
    end
  end

  describe "#latest_available_version" do
    it "returns latest available version (non-eager)" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      mi_fresh = described_class[mi.id]
      expect(mi_fresh.latest_available_version.id).to eq(v1.id)

      v1.destroy
      v2.destroy
    end

    it "returns latest available version (eager-loaded)" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      mi_eager = described_class.eager(:versions).where(id: mi.id).first
      expect(mi_eager.latest_available_version.id).to eq(v1.id)

      v1.destroy
      v2.destroy
    end

    it "returns nil when no available versions" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      expect(described_class[mi.id].latest_available_version).to be_nil

      v.destroy
    end
  end

  describe "#available_versions" do
    it "returns all available versions ordered by created_at desc (non-eager)" do
      t = Time.now
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t - 20
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t - 10
      )
      v3 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: t
      )

      mi_fresh = described_class[mi.id]
      avail = mi_fresh.available_versions
      expect(avail.length).to eq(2)
      expect(avail.map(&:id)).to eq([v3.id, v1.id])

      v1.destroy
      v2.destroy
      v3.destroy
    end

    it "returns all available versions ordered by created_at desc (eager-loaded)" do
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

      mi_eager = described_class.eager(:versions).where(id: mi.id).first
      avail = mi_eager.available_versions
      expect(avail.length).to eq(2)
      expect(avail.map(&:id)).to eq([v2.id, v1.id])

      v1.destroy
      v2.destroy
    end
  end

  describe "#versions association" do
    it "returns versions ordered by created_at desc" do
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

      expect(mi.versions.map(&:id)).to eq([v2.id, v1.id])

      v1.destroy
      v2.destroy
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(mi.ubid).to start_with("m1")
    end
  end

  describe "ObjectTag::Cleanup" do
    it "removes referencing access control entries and object tag memberships on destroy" do
      account = Account.create(email: "test-mi@example.com")
      project2 = account.create_project_with_default_policy("mi-test-project", default_policy: false)
      tag = ObjectTag.create(project_id: project2.id, name: "mi-tag")
      tag.add_member(mi.id)
      mi.update(project_id: project2.id)
      ace = AccessControlEntry.create(project_id: project2.id, subject_id: account.id, object_id: mi.id)

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

  describe ".for_project" do
    it "filters by project_id" do
      mi # force creation
      project2 = Project.create(name: "test2")
      mi2 = described_class.create(
        name: "other-image", project_id: project2.id,
        location_id: location.id
      )

      results = described_class.for_project(project.id).all
      expect(results.map(&:id)).to include(mi.id)
      expect(results.map(&:id)).not_to include(mi2.id)

      mi2.destroy
    end
  end
end
