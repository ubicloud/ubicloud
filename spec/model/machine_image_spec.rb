# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MachineImage do
  let(:project) { Project.create(name: "test") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:mi) {
    described_class.create(name: "test-image", project_id: project.id, location_id: location_id)
  }

  def create_version(mi, state: "available", activated_at: nil, version: "20260101-1", created_at: Time.now)
    MachineImageVersion.create(
      machine_image_id: mi.id,
      version: version,
      state: state,
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "test-prefix",
      s3_endpoint: "https://s3.example.com",
      activated_at: activated_at,
      created_at: created_at
    )
  end

  describe ".next_auto_version" do
    it "returns today's date with count 1 when no existing versions" do
      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      today = Date.today.strftime("%Y%m%d")
      expect(result).to eq("#{today}-1")
    end

    it "increments count for same day" do
      today = Date.today.strftime("%Y%m%d")
      create_version(mi, version: "#{today}-1")
      create_version(mi, version: "#{today}-2")

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      expect(result).to eq("#{today}-3")
    end

    it "does not count versions from a different day" do
      create_version(mi, version: "20250101-1")
      create_version(mi, version: "20250101-2")

      result = described_class.next_auto_version(MachineImageVersion.where(machine_image_id: mi.id))
      today = Date.today.strftime("%Y%m%d")
      expect(result).to eq("#{today}-1")
    end
  end

  describe "#display_location" do
    it "returns the location display_name" do
      expect(mi.display_location).to eq("eu-central-h1")
    end
  end

  describe "#path" do
    it "returns the expected path format" do
      expect(mi.path).to eq("/location/eu-central-h1/machine-image/#{mi.ubid}")
    end
  end

  describe "#active_version" do
    it "returns nil when no versions are activated" do
      create_version(mi, state: "available")
      expect(mi.active_version).to be_nil
    end

    it "returns the version with the most recent activated_at" do
      create_version(mi, version: "v1", activated_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)
      expect(mi.active_version.id).to eq(v2.id)
    end

    it "returns the active version when versions are eager-loaded" do
      create_version(mi, version: "v1", activated_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", activated_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version.id).to eq(v2.id)
    end

    it "returns nil when eager-loaded with no activated versions" do
      create_version(mi, version: "v1")
      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.active_version).to be_nil
    end
  end

  describe "#latest_available_version" do
    it "returns nil when no available versions exist" do
      create_version(mi, state: "creating")
      expect(mi.latest_available_version).to be_nil
    end

    it "returns the most recently created available version" do
      create_version(mi, version: "v1", state: "available", created_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)
      create_version(mi, version: "v3", state: "creating", created_at: Time.now + 3600)

      expect(mi.latest_available_version.id).to eq(v2.id)
    end

    it "works with eager-loaded versions" do
      create_version(mi, version: "v1", state: "available", created_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      expect(eager_mi.latest_available_version.id).to eq(v2.id)
    end
  end

  describe "#available_versions" do
    it "returns empty array when no available versions" do
      create_version(mi, state: "creating")
      expect(mi.available_versions).to be_empty
    end

    it "returns only available versions ordered by created_at desc" do
      v1 = create_version(mi, version: "v1", state: "available", created_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)
      create_version(mi, version: "v3", state: "creating")

      result = mi.available_versions
      expect(result.length).to eq(2)
      expect(result.first.id).to eq(v2.id)
      expect(result.last.id).to eq(v1.id)
    end

    it "works with eager-loaded versions" do
      create_version(mi, version: "v1", state: "available", created_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", state: "available", created_at: Time.now)

      eager_mi = described_class.eager(:versions).where(id: mi.id).first
      result = eager_mi.available_versions
      expect(result.length).to eq(2)
      expect(result.first.id).to eq(v2.id)
    end
  end

  describe "associations" do
    it "has many versions ordered by created_at desc" do
      create_version(mi, version: "v1", created_at: Time.now - 3600)
      v2 = create_version(mi, version: "v2", created_at: Time.now)

      versions = mi.versions
      expect(versions.length).to eq(2)
      expect(versions.first.id).to eq(v2.id)
    end

    it "belongs to a project" do
      expect(mi.project.id).to eq(project.id)
    end

    it "belongs to a location" do
      expect(mi.location_id).to eq(location_id)
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
      v1 = create_version(mi, version: "v1")
      v2 = create_version(mi, version: "v2")

      mi.destroy
      expect(MachineImageVersion[v1.id]).to be_nil
      expect(MachineImageVersion[v2.id]).to be_nil
    end
  end

  describe "dataset_module" do
    it "filters by project with for_project" do
      mi # force creation before query
      other_project = Project.create(name: "other")
      other_mi = described_class.create(name: "other-image", project_id: other_project.id, location_id: location_id)

      result = described_class.for_project(project.id).all
      expect(result.map(&:id)).to include(mi.id)
      expect(result.map(&:id)).not_to include(other_mi.id)
    end
  end
end
