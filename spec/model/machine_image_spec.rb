# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }

  let(:mi) {
    described_class.create(
      name: "test-image",
      description: "test machine image",
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID
    )
  }

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 when no versions exist for today" do
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: nil))
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")
    end

    it "increments N for same-day versions" do
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

    it "does not count versions from a different day" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "20240101-1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      result = described_class.next_auto_version(mi.versions_dataset)
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq(mi.location.display_name)
    end
  end

  describe "#path" do
    it "returns the path with location and ubid" do
      expect(mi.path).to eq("/location/#{mi.display_location}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    let!(:v1) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now - 3600
      )
    }

    let!(:v2) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )
    }

    it "returns the version with the most recent activated_at (non-eager-loaded)" do
      result = described_class[mi.id].active_version
      expect(result.id).to eq(v2.id)
    end

    it "returns the version with the most recent activated_at (eager-loaded)" do
      image = described_class.eager(:versions).where(id: mi.id).first
      result = image.active_version
      expect(result.id).to eq(v2.id)
    end

    it "returns nil when no versions are activated" do
      v1.update(activated_at: nil)
      v2.update(activated_at: nil)
      expect(described_class[mi.id].active_version).to be_nil
    end
  end

  describe "#latest_available_version" do
    let!(:v_available) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
    }

    let!(:v_creating) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
    }

    it "returns latest available version (non-eager-loaded)" do
      result = described_class[mi.id].latest_available_version
      expect(result.id).to eq(v_available.id)
    end

    it "returns latest available version (eager-loaded)" do
      image = described_class.eager(:versions).where(id: mi.id).first
      result = image.latest_available_version
      expect(result.id).to eq(v_available.id)
    end

    it "returns nil when no available versions exist" do
      v_available.update(state: "creating")
      expect(described_class[mi.id].latest_available_version).to be_nil
    end
  end

  describe "#available_versions" do
    it "returns only versions with state 'available'" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      result = mi.reload.available_versions
      expect(result.length).to eq(2)
      expect(result.map(&:version)).to contain_exactly("v1", "v3")
    end

    it "returns empty array when no available versions" do
      expect(mi.available_versions).to be_empty
    end

    it "works with eager-loaded versions" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      image = described_class.eager(:versions).where(id: mi.id).first
      expect(image.available_versions.length).to eq(1)
    end
  end

  describe "#versions association" do
    it "orders versions by created_at DESC" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now - 3600
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        created_at: Time.now
      )

      versions = mi.reload.versions
      expect(versions.first.id).to eq(v2.id)
      expect(versions.last.id).to eq(v1.id)
    end
  end

  describe "#before_destroy" do
    it "destroys all versions before destroying the image" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      mi.destroy
      expect(described_class[mi.id]).to be_nil
      expect(MachineImageVersion.where(machine_image_id: mi.id).count).to eq(0)
    end
  end

  describe ".for_project" do
    it "filters images by project" do
      mi # trigger creation
      other_project = Project.create(name: "other-project")
      other_mi = described_class.create(
        name: "other-image", project_id: other_project.id,
        location_id: Location::HETZNER_FSN1_ID
      )

      results = described_class.for_project(project.id).all
      expect(results.map(&:id)).to include(mi.id)
      expect(results.map(&:id)).not_to include(other_mi.id)
    end
  end

  it "has a project association" do
    expect(mi.project.id).to eq(project.id)
  end

  it "generates a ubid" do
    expect(mi.ubid).not_to be_nil
    expect(mi.ubid).to start_with("m1")
  end

  describe "ObjectTag::Cleanup" do
    it "removes referencing access control entries and object tag memberships on destroy" do
      account = Account.create(email: "mi-cleanup@example.com")
      proj = account.create_project_with_default_policy("proj-mi-cleanup", default_policy: false)
      mi.update(project_id: proj.id)
      tag = ObjectTag.create(project_id: proj.id, name: "t")
      tag.add_member(mi.id)
      ace = AccessControlEntry.create(project_id: proj.id, subject_id: account.id, object_id: mi.id)

      mi.destroy
      expect(tag.member_ids).to be_empty
      expect(ace).not_to be_exists
    end
  end
end
