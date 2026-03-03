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

  def create_version(attrs = {})
    MachineImageVersion.create({
      machine_image_id: mi.id,
      version: "v1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com"
    }.merge(attrs))
  end

  describe ".next_auto_version" do
    it "returns today's date with count 1 when no versions exist" do
      today = Date.today.strftime("%Y%m%d")
      result = described_class.next_auto_version(MachineImageVersion.dataset.where(id: nil))
      expect(result).to eq("#{today}-1")
    end

    it "increments count for same day" do
      today = Date.today.strftime("%Y%m%d")
      create_version(version: "#{today}-1")
      create_version(version: "#{today}-2")
      result = described_class.next_auto_version(mi.versions_dataset)
      expect(result).to eq("#{today}-3")
    end

    it "resets count for different day prefix" do
      create_version(version: "20200101-1")
      today = Date.today.strftime("%Y%m%d")
      result = described_class.next_auto_version(mi.versions_dataset)
      expect(result).to eq("#{today}-1")
    end
  end

  describe "#display_location" do
    it "delegates to location.display_name" do
      expect(mi.display_location).to eq("eu-central-h1")
    end
  end

  describe "#path" do
    it "returns the location-scoped path with ubid" do
      expect(mi.path).to eq("/location/eu-central-h1/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    it "returns the version with most recent activated_at" do
      create_version(version: "v1", activated_at: Time.now - 100)
      v2 = create_version(version: "v2", activated_at: Time.now)
      expect(mi.active_version.id).to eq(v2.id)
    end

    it "returns nil when no versions have activated_at" do
      create_version(version: "v1")
      expect(mi.active_version).to be_nil
    end

    it "works with eager-loaded versions" do
      create_version(version: "v1", activated_at: Time.now - 100)
      v2 = create_version(version: "v2", activated_at: Time.now)
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v2.id)
    end
  end

  describe "#latest_available_version" do
    let(:t1) { Time.now - 200 }
    let(:t2) { Time.now - 100 }

    it "returns the most recently created available version" do
      create_version(version: "v1", created_at: t1)
      v2 = create_version(version: "v2", created_at: t2)
      expect(mi.latest_available_version.id).to eq(v2.id)
    end

    it "skips non-available versions" do
      v1 = create_version(version: "v1", created_at: t1)
      create_version(version: "v2", state: "creating", created_at: t2)
      expect(mi.latest_available_version.id).to eq(v1.id)
    end

    it "returns nil when no available versions exist" do
      create_version(version: "v1", state: "creating")
      expect(mi.latest_available_version).to be_nil
    end

    it "works with eager-loaded versions" do
      create_version(version: "v1", created_at: t1)
      v2 = create_version(version: "v2", created_at: t2)
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v2.id)
    end
  end

  describe "#available_versions" do
    let(:t1) { Time.now - 300 }
    let(:t2) { Time.now - 200 }
    let(:t3) { Time.now - 100 }

    it "returns all available versions ordered by created_at DESC" do
      v1 = create_version(version: "v1", created_at: t1)
      create_version(version: "v2", state: "creating", created_at: t2)
      v3 = create_version(version: "v3", created_at: t3)
      result = mi.available_versions
      expect(result.map(&:id)).to eq([v3.id, v1.id])
    end

    it "returns empty array when no available versions" do
      create_version(version: "v1", state: "creating")
      expect(mi.available_versions).to be_empty
    end

    it "works with eager-loaded versions" do
      v1 = create_version(version: "v1", created_at: t1)
      v2 = create_version(version: "v2", created_at: t2)
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.available_versions.map(&:id)).to eq([v2.id, v1.id])
    end
  end

  describe "#before_destroy" do
    it "destroys all versions before destroying self" do
      v1 = create_version(version: "v1")
      v2 = create_version(version: "v2")
      mi.destroy
      expect(MachineImageVersion[v1.id]).to be_nil
      expect(MachineImageVersion[v2.id]).to be_nil
      expect(described_class[mi.id]).to be_nil
    end
  end

  describe "associations" do
    it "has versions ordered by created_at DESC" do
      v1 = create_version(version: "v1", created_at: Time.now - 200)
      v2 = create_version(version: "v2", created_at: Time.now - 100)
      expect(mi.versions.map(&:id)).to eq([v2.id, v1.id])
    end

    it "belongs to a project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to a location" do
      expect(mi.location).not_to be_nil
    end
  end

  it "generates a ubid" do
    expect(mi.ubid).to start_with("m1")
  end

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
