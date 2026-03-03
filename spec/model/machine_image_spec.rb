# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test-mi-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    described_class.create(name: "test-image", project_id: project.id, location_id: location.id)
  }

  def create_version(mi, **overrides)
    defaults = {machine_image_id: mi.id, version: "v1", state: "available",
                size_gib: 10, s3_bucket: "b", s3_prefix: "p", s3_endpoint: "e"}
    MachineImageVersion.create(**defaults.merge(overrides))
  end

  describe ".next_auto_version" do
    it "returns today's date with counter 1 when no versions exist" do
      today = Date.today.strftime("%Y%m%d")
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: nil))
      expect(result).to eq("#{today}-1")
    end

    it "increments counter for existing versions on the same day" do
      today = Date.today.strftime("%Y%m%d")
      create_version(mi, version: "#{today}-1")
      expect(described_class.next_auto_version(mi.versions_dataset)).to eq("#{today}-2")

      create_version(mi, version: "#{today}-2")
      expect(described_class.next_auto_version(mi.versions_dataset)).to eq("#{today}-3")
    end

    it "does not count versions from a different day" do
      today = Date.today.strftime("%Y%m%d")
      create_version(mi, version: "20250101-1")
      expect(described_class.next_auto_version(mi.versions_dataset)).to eq("#{today}-1")
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "returns the path with location and ubid" do
      expect(mi.path).to eq("/location/#{location.display_name}/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    it "returns the version with the most recent activated_at" do
      create_version(mi, version: "v1", activated_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)
      expect(mi.active_version.id).to eq(v2.id)
    end

    it "returns nil when no versions are activated" do
      create_version(mi, version: "v1")
      expect(mi.active_version).to be_nil
    end

    it "works with eager-loaded versions" do
      create_version(mi, version: "v1", activated_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)

      loaded = described_class.eager(:versions).where(id: mi.id).first
      expect(loaded.active_version.id).to eq(v2.id)
    end

    it "returns nil with eager-loaded versions when none activated" do
      create_version(mi, version: "v1")
      loaded = described_class.eager(:versions).where(id: mi.id).first
      expect(loaded.active_version).to be_nil
    end
  end

  describe "#latest_available_version" do
    it "returns the most recently created available version" do
      create_version(mi, version: "v1", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2")
      expect(mi.latest_available_version.id).to eq(v2.id)
    end

    it "skips non-available versions" do
      v1 = create_version(mi, version: "v1")
      create_version(mi, version: "v2", state: "creating")
      expect(mi.latest_available_version.id).to eq(v1.id)
    end

    it "returns nil when no available versions exist" do
      create_version(mi, version: "v1", state: "creating")
      expect(mi.latest_available_version).to be_nil
    end

    it "works with eager-loaded versions" do
      v1 = create_version(mi, version: "v1")
      create_version(mi, version: "v2", state: "failed")

      loaded = described_class.eager(:versions).where(id: mi.id).first
      expect(loaded.latest_available_version.id).to eq(v1.id)
    end
  end

  describe "#available_versions" do
    it "returns all available versions ordered by created_at desc" do
      v1 = create_version(mi, version: "v1", created_at: Time.now - 200)
      create_version(mi, version: "v2", state: "creating", created_at: Time.now - 100)
      v3 = create_version(mi, version: "v3")
      expect(mi.available_versions.map(&:id)).to eq([v3.id, v1.id])
    end

    it "returns empty array when none are available" do
      create_version(mi, version: "v1", state: "creating")
      expect(mi.available_versions).to be_empty
    end

    it "works with eager-loaded versions" do
      v1 = create_version(mi, version: "v1")
      loaded = described_class.eager(:versions).where(id: mi.id).first
      expect(loaded.available_versions.map(&:id)).to eq([v1.id])
    end
  end

  describe "#before_destroy" do
    it "destroys all versions before destroying itself" do
      v1 = create_version(mi, version: "v1")
      mi.destroy
      expect(MachineImageVersion[v1.id]).to be_nil
      expect(described_class[mi.id]).to be_nil
    end
  end

  describe "associations" do
    it "has versions ordered by created_at desc" do
      v1 = create_version(mi, version: "v1", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2")
      expect(mi.versions.map(&:id)).to eq([v2.id, v1.id])
    end

    it "belongs to a project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to a location" do
      expect(mi.location.id).to eq(location.id)
    end
  end

  it "removes referencing access control entries and object tag memberships" do
    account = Account.create(email: "test-mi@example.com")
    proj = account.create_project_with_default_policy("mi-project", default_policy: false)
    mi2 = described_class.create(name: "cleanup-image", project_id: proj.id, location_id: location.id)
    tag = ObjectTag.create(project_id: proj.id, name: "mi-tag")
    tag.add_member(mi2.id)
    ace = AccessControlEntry.create(project_id: proj.id, subject_id: account.id, object_id: mi2.id)

    mi2.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end
end
