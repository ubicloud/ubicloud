# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    described_class.create(
      name: "test-image",
      project_id: project.id,
      location_id: location.id
    )
  }

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 for the first version of the day" do
      result = described_class.next_auto_version(MachineImageVersion.dataset)
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")
    end

    it "increments N for versions on the same day" do
      today = Date.today.strftime("%Y%m%d")
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "#{today}-1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "#{today}-2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      result = described_class.next_auto_version(mi.versions_dataset)
      expect(result).to eq("#{today}-3")
    end

    it "does not count versions from different days" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "20200101-1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      result = described_class.next_auto_version(mi.versions_dataset)
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "returns the resource path" do
      expect(mi.path).to eq("/location/#{location.display_name}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    it "returns the version with the most recent activated_at" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now - 100
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )
      expect(mi.active_version.id).to eq(v2.id)
    end

    it "returns nil when no version is activated" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      expect(mi.active_version).to be_nil
    end

    it "uses eager-loaded versions when available" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v.id)
    end
  end

  describe "#latest_available_version" do
    it "returns the latest version with state available" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      expect(mi.latest_available_version.id).to eq(v1.id)
    end

    it "returns nil when no available versions exist" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      expect(mi.latest_available_version).to be_nil
    end

    it "uses eager-loaded versions when available" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v.id)
    end
  end

  describe "#available_versions" do
    it "returns all versions with state available ordered by created_at desc" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now - 200
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now - 100
      )
      v3 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now
      )
      result = mi.available_versions
      expect(result.map(&:id)).to eq([v3.id, v1.id])
    end

    it "returns empty array when no available versions" do
      expect(mi.available_versions).to eq([])
    end

    it "uses eager-loaded versions when available" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.available_versions.map(&:id)).to eq([v.id])
    end
  end

  describe "associations" do
    it "has many versions ordered by created_at desc" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now - 100
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now
      )
      expect(mi.versions.map(&:id)).to eq([v2.id, v1.id])
    end

    it "belongs to a project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to a location" do
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
      proj = account.create_project_with_default_policy("mi-project", default_policy: false)
      mi.update(project_id: proj.id)
      tag = ObjectTag.create(project_id: proj.id, name: "t")
      tag.add_member(mi.id)
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

  describe ".for_project" do
    it "filters by project_id" do
      mi # force creation
      other_project = Project.create(name: "other")
      described_class.create(
        name: "other-image", project_id: other_project.id, location_id: location.id
      )
      expect(described_class.for_project(project.id).all.map(&:id)).to eq([mi.id])
    end
  end
end
