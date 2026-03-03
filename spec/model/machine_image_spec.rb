# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:mi) {
    described_class.create(
      name: "test-image",
      description: "A test image",
      project_id: project.id,
      location_id: location.id
    )
  }

  describe ".next_auto_version" do
    it "returns YYYYMMDD-1 when no versions exist for today" do
      today = Date.today.strftime("%Y%m%d")
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: nil))
      expect(result).to eq("#{today}-1")
    end

    it "increments N for same day" do
      today = Date.today.strftime("%Y%m%d")
      v1 = create_version(mi, version: "#{today}-1")
      v2 = create_version(mi, version: "#{today}-2")

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{today}-3")

      v1.destroy
      v2.destroy
    end

    it "resets N for a different day prefix" do
      v = create_version(mi, version: "20200101-5")

      today = Date.today.strftime("%Y%m%d")
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
    it "returns the version with the most recent activated_at" do
      _v1 = create_version(mi, version: "v1", activated_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)
      _v3 = create_version(mi, version: "v3") # no activated_at

      expect(mi.active_version.id).to eq(v2.id)
    end

    it "returns nil when no versions are activated" do
      create_version(mi, version: "v1")
      expect(mi.active_version).to be_nil
    end

    it "uses eager-loaded versions when available" do
      _v1 = create_version(mi, version: "v1", activated_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v2.id)
    end

    it "returns nil from eager-loaded path when none activated" do
      create_version(mi, version: "v1")
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version).to be_nil
    end
  end

  describe "#latest_available_version" do
    it "returns the latest version with state=available" do
      _v1 = create_version(mi, version: "v1", state: "available", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)
      _v3 = create_version(mi, version: "v3", state: "creating")

      expect(mi.latest_available_version.id).to eq(v2.id)
    end

    it "returns nil when no available versions exist" do
      create_version(mi, version: "v1", state: "creating")
      expect(mi.latest_available_version).to be_nil
    end

    it "uses eager-loaded versions when available" do
      _v1 = create_version(mi, version: "v1", state: "available", created_at: Time.now - 100)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v2.id)
    end
  end

  describe "#available_versions" do
    it "returns all versions with state=available ordered by created_at DESC" do
      v1 = create_version(mi, version: "v1", state: "available", created_at: Time.now - 200)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now - 100)
      _v3 = create_version(mi, version: "v3", state: "creating")

      result = mi.available_versions
      expect(result.map(&:id)).to eq([v2.id, v1.id])
    end

    it "returns empty array when no available versions" do
      create_version(mi, version: "v1", state: "creating")
      expect(mi.available_versions).to be_empty
    end

    it "uses eager-loaded versions when available" do
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
      expect(mi.project).to eq(project)
    end

    it "belongs to a location" do
      expect(mi.location).to eq(location)
    end
  end

  describe "ResourceMethods" do
    it "generates a UBID" do
      expect(mi.ubid).to start_with("m1")
    end
  end

  describe "ObjectTag::Cleanup" do
    it "removes referencing access control entries and object tag memberships on destroy" do
      account = Account.create(email: "cleanup-test@example.com")
      proj = account.create_project_with_default_policy("cleanup-proj", default_policy: false)
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
      v1 = create_version(mi, version: "v1")
      v2 = create_version(mi, version: "v2")
      mi.destroy
      expect(MachineImageVersion[v1.id]).to be_nil
      expect(MachineImageVersion[v2.id]).to be_nil
    end
  end

  private

  def create_version(image, version:, state: "creating", activated_at: nil, created_at: nil)
    attrs = {
      machine_image_id: image.id,
      version: version,
      state: state,
      size_gib: 20,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    }
    attrs[:activated_at] = activated_at if activated_at
    v = MachineImageVersion.create(attrs)
    v.update(created_at: created_at) if created_at
    v
  end
end
