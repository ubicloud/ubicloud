# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:mi) {
    described_class.create(
      name: "test-image",
      project_id: project.id,
      location_id: location_id
    )
  }

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 when no versions exist for today" do
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: nil))
      expect(result).to eq("#{Date.today.strftime("%Y%m%d")}-1")
    end

    it "increments N for same day" do
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

    it "ignores versions from a different day" do
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
      expect(mi.display_location).to eq(Location[location_id].display_name)
    end
  end

  describe "#path" do
    it "returns /location/LOC/machine-image/UBID" do
      expect(mi.path).to eq("/location/#{mi.display_location}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    let!(:v_inactive) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
    }

    let!(:v_old_active) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now - 3600
      )
    }

    let!(:v_new_active) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e",
        activated_at: Time.now
      )
    }

    it "returns version with most recent activated_at (non-eager-loaded)" do
      fresh = described_class[mi.id]
      expect(fresh.active_version.id).to eq(v_new_active.id)
    end

    it "returns version with most recent activated_at (eager-loaded)" do
      fresh = described_class.eager(:versions).where(id: mi.id).first
      expect(fresh.active_version.id).to eq(v_new_active.id)
    end

    it "returns nil when no versions are activated" do
      v_old_active.update(activated_at: nil)
      v_new_active.update(activated_at: nil)
      fresh = described_class[mi.id]
      expect(fresh.active_version).to be_nil
    end
  end

  describe "#latest_available_version" do
    let!(:v_creating) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
    }

    let!(:v_available_old) {
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      DB[:machine_image_version].where(id: v.id).update(created_at: Time.now - 3600)
      v.reload
    }

    let!(:v_available_new) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
    }

    it "returns latest available version (non-eager-loaded)" do
      fresh = described_class[mi.id]
      expect(fresh.latest_available_version.id).to eq(v_available_new.id)
    end

    it "returns latest available version (eager-loaded)" do
      fresh = described_class.eager(:versions).where(id: mi.id).first
      expect(fresh.latest_available_version.id).to eq(v_available_new.id)
    end

    it "returns nil when no versions are available" do
      v_available_old.update(state: "failed")
      v_available_new.update(state: "failed")
      fresh = described_class[mi.id]
      expect(fresh.latest_available_version).to be_nil
    end
  end

  describe "#available_versions" do
    it "returns all versions with state available (non-eager-loaded)" do
      v_avail = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "creating",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      fresh = described_class[mi.id]
      expect(fresh.available_versions.map(&:id)).to eq([v_avail.id])
    end

    it "returns all versions with state available (eager-loaded)" do
      v_avail = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "failed",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      fresh = described_class.eager(:versions).where(id: mi.id).first
      expect(fresh.available_versions.map(&:id)).to eq([v_avail.id])
    end

    it "returns empty array when none available" do
      fresh = described_class[mi.id]
      expect(fresh.available_versions).to eq([])
    end
  end

  describe "#before_destroy" do
    it "destroys all versions before destroying the image" do
      v = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      mi.destroy
      expect(described_class[mi.id]).to be_nil
      expect(MachineImageVersion[v.id]).to be_nil
    end
  end

  describe "associations" do
    it "has versions ordered by created_at DESC" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )
      DB[:machine_image_version].where(id: v1.id).update(created_at: Time.now - 3600)
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"
      )

      expect(mi.reload.versions.map(&:id).first).to eq(v2.id)
    end

    it "belongs to a project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to a location" do
      expect(mi.location.id).to eq(location_id)
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(mi.ubid).to start_with("m1")
    end
  end

  describe "ObjectTag::Cleanup" do
    it "removes referencing access control entries and object tag memberships" do
      account = Account.create(email: "test@example.com")
      proj = account.create_project_with_default_policy("project-1", default_policy: false)
      tag = ObjectTag.create(project_id: proj.id, name: "t")
      tag.add_member(mi.id)
      mi.update(project_id: proj.id)
      ace = AccessControlEntry.create(project_id: proj.id, subject_id: account.id, object_id: mi.id)

      mi.destroy
      expect(tag.member_ids).to be_empty
      expect(ace).not_to be_exists
    end
  end

  describe "dataset" do
    it "filters by project with for_project" do
      mi # create it
      other_project = Project.create(name: "other")
      other_mi = described_class.create(
        name: "other-image", project_id: other_project.id, location_id: location_id
      )

      results = described_class.for_project(project.id).all
      expect(results.map(&:id)).to include(mi.id)
      expect(results.map(&:id)).not_to include(other_mi.id)
    end
  end
end
