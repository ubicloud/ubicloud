# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    described_class.create(
      name: "test-image",
      description: "test desc",
      project_id: project.id,
      location_id: location.id,
      arch: "arm64"
    )
  }

  def create_version(mi, state: "available", version: "v1", activated_at: nil, created_at: nil)
    v = MachineImageVersion.create(
      machine_image_id: mi.id,
      version: version,
      state: state,
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com"
    )
    updates = {}
    updates[:activated_at] = activated_at if activated_at
    updates[:created_at] = created_at if created_at
    v.update(updates) unless updates.empty?
    v
  end

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 when no versions exist" do
      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      today = Date.today.strftime("%Y%m%d")
      expect(result).to eq("#{today}-1")
    end

    it "increments N for same day" do
      today = Date.today.strftime("%Y%m%d")
      create_version(mi, version: "#{today}-1")
      create_version(mi, version: "#{today}-2")

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{today}-3")
    end

    it "does not count versions from a different day" do
      create_version(mi, version: "20200101-1")
      create_version(mi, version: "20200101-2")

      today = Date.today.strftime("%Y%m%d")
      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{today}-1")
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq(location.display_name)
    end
  end

  describe "#path" do
    it "returns the correct path with location and ubid" do
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

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v2.id)
    end

    it "works without eager-loaded versions" do
      create_version(mi, version: "v1", activated_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)

      fresh_mi = described_class[mi.id]
      expect(fresh_mi.active_version.id).to eq(v2.id)
    end
  end

  describe "#latest_available_version" do
    it "returns the latest available version by created_at" do
      create_version(mi, version: "v1", state: "available", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)

      expect(mi.latest_available_version.id).to eq(v2.id)
    end

    it "ignores non-available versions" do
      v1 = create_version(mi, version: "v1", state: "available")
      create_version(mi, version: "v2", state: "creating")

      expect(mi.latest_available_version.id).to eq(v1.id)
    end

    it "returns nil when no available versions exist" do
      create_version(mi, version: "v1", state: "creating")

      expect(mi.latest_available_version).to be_nil
    end

    it "works with eager-loaded versions" do
      create_version(mi, version: "v1", state: "available", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v2.id)
    end
  end

  describe "#available_versions" do
    it "returns all available versions ordered by created_at DESC" do
      v1 = create_version(mi, version: "v1", state: "available", created_at: Time.now - 200)
      create_version(mi, version: "v2", state: "creating")
      v3 = create_version(mi, version: "v3", state: "available", created_at: Time.now - 100)

      result = mi.available_versions
      expect(result.map(&:id)).to eq([v3.id, v1.id])
    end

    it "returns empty array when no available versions exist" do
      create_version(mi, version: "v1", state: "creating")

      expect(mi.available_versions).to be_empty
    end

    it "works with eager-loaded versions" do
      v1 = create_version(mi, version: "v1", state: "available", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      result = eager_mi.available_versions
      expect(result.map(&:id)).to eq([v2.id, v1.id])
    end
  end

  describe "associations" do
    it "has many versions ordered by created_at DESC" do
      v1 = create_version(mi, version: "v1", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", created_at: Time.now)

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
    it "generates a ubid" do
      expect(mi.ubid).to match(/\A[a-z0-9]{26}\z/)
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

  describe "#before_destroy" do
    it "destroys all versions before destroying the image" do
      v1 = create_version(mi, version: "v1")
      v2 = create_version(mi, version: "v2")

      mi.destroy
      expect(MachineImageVersion[v1.id]).to be_nil
      expect(MachineImageVersion[v2.id]).to be_nil
      expect(described_class[mi.id]).to be_nil
    end
  end
end
