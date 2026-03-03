# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:mi) {
    described_class.create(
      name: "test-image",
      description: "test desc",
      project_id: project.id,
      location_id: location_id
    )
  }

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 for first version of the day" do
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: nil))
      today = Date.today.strftime("%Y%m%d")
      expect(result).to eq("#{today}-1")
    end

    it "increments the counter for same-day versions" do
      today = Date.today.strftime("%Y%m%d")
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "#{today}-1", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "#{today}-2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )

      result = described_class.next_auto_version(mi.versions_dataset)
      expect(result).to eq("#{today}-3")
    end

    it "does not count versions from other days" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "20240101-1", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )

      result = described_class.next_auto_version(mi.versions_dataset)
      today = Date.today.strftime("%Y%m%d")
      expect(result).to eq("#{today}-1")
    end
  end

  describe "#display_location" do
    it "returns the location display_name" do
      loc = Location[location_id]
      expect(mi.display_location).to eq(loc.display_name)
    end
  end

  describe "#path" do
    it "returns path with location and ubid" do
      loc = Location[location_id]
      expect(mi.path).to eq("/location/#{loc.display_name}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    let!(:v_inactive) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
    }

    let!(:v_old_active) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        activated_at: Time.now - 3600
      )
    }

    let!(:v_latest_active) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        activated_at: Time.now
      )
    }

    it "returns the version with the most recent activated_at (non-eager)" do
      fresh_mi = described_class[mi.id]
      expect(fresh_mi.active_version.id).to eq(v_latest_active.id)
    end

    it "returns the version with the most recent activated_at (eager-loaded)" do
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v_latest_active.id)
    end

    it "returns nil when no versions are activated" do
      v_old_active.update(activated_at: nil)
      v_latest_active.update(activated_at: nil)
      fresh_mi = described_class[mi.id]
      expect(fresh_mi.active_version).to be_nil
    end
  end

  describe "#latest_available_version" do
    let!(:v_creating) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        created_at: Time.now - 7200
      )
    }

    let!(:v_available_old) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        created_at: Time.now - 3600
      )
    }

    let!(:v_available_new) {
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        created_at: Time.now
      )
    }

    it "returns the latest available version by created_at (non-eager)" do
      fresh_mi = described_class[mi.id]
      expect(fresh_mi.latest_available_version.id).to eq(v_available_new.id)
    end

    it "returns the latest available version by created_at (eager-loaded)" do
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v_available_new.id)
    end

    it "returns nil when no versions are available" do
      v_available_old.update(state: "failed")
      v_available_new.update(state: "failed")
      fresh_mi = described_class[mi.id]
      expect(fresh_mi.latest_available_version).to be_nil
    end
  end

  describe "#available_versions" do
    it "returns only versions with state available" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      v3 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v3", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )

      fresh_mi = described_class[mi.id]
      ids = fresh_mi.available_versions.map(&:id)
      expect(ids).to contain_exactly(v2.id, v3.id)
    end

    it "returns empty array when no versions are available" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "creating",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      fresh_mi = described_class[mi.id]
      expect(fresh_mi.available_versions).to be_empty
    end
  end

  describe "associations" do
    it "has versions ordered by created_at DESC" do
      v1 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        created_at: Time.now - 3600
      )
      v2 = MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com",
        created_at: Time.now
      )

      mi.reload
      expect(mi.versions.first.id).to eq(v2.id)
      expect(mi.versions.last.id).to eq(v1.id)
    end

    it "belongs to a project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to a location" do
      expect(mi.location.id).to eq(location_id)
    end
  end

  describe "#before_destroy" do
    it "destroys all versions before destroying itself" do
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v1", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )
      MachineImageVersion.create(
        machine_image_id: mi.id, version: "v2", state: "available",
        size_gib: 20, s3_bucket: "b", s3_prefix: "p/", s3_endpoint: "https://r2.example.com"
      )

      mi.destroy
      expect(MachineImageVersion.where(machine_image_id: mi.id).count).to eq(0)
    end
  end
end
