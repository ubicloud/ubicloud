# frozen_string_literal: true

require_relative "spec_helper"
require "aws-sdk-ec2"

RSpec.describe Location do
  subject(:p2_loc) { described_class.create(name: "l2", display_name: "l2", ui_name: "l2", visible: true, provider: "aws", project_id: p2_id) }

  let(:p1_id) { Project.create(name: "pj1").id }

  let(:p2_id) { Project.create(name: "pj2").id }

  let(:p1_loc) { described_class.create(name: "l1", display_name: "l1", ui_name: "l1", visible: true, provider: "aws", project_id: p1_id) }

  it ".for_project filters dataset to given project and non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.for_project(p1_id).select_order_map(:name)).to eq ["gcp-us-central1", "gcp-us-east4", "github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l1", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom", "us-east-1", "us-west-2", "us-west-u1-ps"]
    expect(described_class.for_project(p2_id).select_order_map(:name)).to eq ["gcp-us-central1", "gcp-us-east4", "github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l2", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom", "us-east-1", "us-west-2", "us-west-u1-ps"]
  end

  it ".visible_or_for_project filters dataset to given project and visible non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.visible_or_for_project(p1_id, []).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p2_id, []).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l2", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p1_id, []).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p1_id, ["latitude-ai"]).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "latitude-ai", "leaseweb-wdc02"]
  end

  it "#visible_or_for_project? returns whether the location is visible or related to the given project" do
    expect(p1_loc.visible_or_for_project?(p1_id, [])).to be true
    expect(p1_loc.visible_or_for_project?(p2_id, [])).to be false
    expect(p2_loc.visible_or_for_project?(p2_id, [])).to be true
    expect(p2_loc.visible_or_for_project?(p1_id, [])).to be false
    expect(described_class[name: "hetzner-fsn1"].visible_or_for_project?(p1_id, [])).to be true
    expect(described_class[name: "github-runners"].visible_or_for_project?(p1_id, [])).to be false
    expect(described_class[name: "latitude-ai"].visible_or_for_project?(p1_id, [])).to be false
    expect(described_class[name: "latitude-ai"].visible_or_for_project?(p1_id, ["latitude-ai"])).to be true
  end

  it "#provider_dispatcher_group_name returns the provider dispatch name" do
    expect(p2_loc.provider_dispatcher_group_name).to eq("aws")
    p2_loc.update(provider: "hetzner")
    expect(p2_loc.provider_dispatcher_group_name).to eq("metal")
  end

  describe ".postgres_locations" do
    it "without arg returns metal and AWS public locations but no GCP" do
      names = described_class.postgres_locations.map(&:name)

      expect(names).to include("hetzner-fsn1", "leaseweb-wdc02")
      expect(names).to include("us-east-1", "us-west-2")
      expect(names).not_to include("gcp-us-central1")
      expect(names).not_to include("github-runners")
    end

    it "excludes a visible: true GCP public location when arg is nil (no visible bypass for GCP)" do
      described_class[name: "gcp-us-central1"].update(visible: true)
      names = described_class.postgres_locations.map(&:name)
      expect(names).not_to include("gcp-us-central1")
    end

    it "with empty array arg behaves like nil (still no GCP)" do
      names = described_class.postgres_locations([]).map(&:name)
      expect(names).to include("hetzner-fsn1", "leaseweb-wdc02", "us-east-1", "us-west-2")
      expect(names).not_to include("gcp-us-central1")
    end

    it "with array containing a GCP region name includes that GCP region" do
      names = described_class.postgres_locations(["gcp-us-central1"]).map(&:name)
      expect(names).to include("gcp-us-central1")
      expect(names).to include("hetzner-fsn1", "leaseweb-wdc02", "us-east-1", "us-west-2")
    end

    it "excludes BYOC GCP locations even when their name is in the array" do
      described_class.create(name: "my-gcp", display_name: "my-gcp", ui_name: "my-gcp", visible: true, provider: "gcp", project_id: p1_id)
      names = described_class.postgres_locations(["my-gcp"]).map(&:name)
      expect(names).not_to include("my-gcp")
    end

    it "excludes BYOC AWS locations" do
      described_class.create(name: "my-aws", display_name: "my-aws", ui_name: "my-aws", visible: true, provider: "aws", project_id: p1_id)
      names = described_class.postgres_locations.map(&:name)
      expect(names).not_to include("my-aws")
    end

    it "excludes a project-owned location even if its name matches a public metal location" do
      described_class.create(name: "hetzner-fsn1", display_name: "shadow-hetzner-fsn1", ui_name: "shadow-hetzner-fsn1", visible: true, provider: "hetzner", project_id: p1_id)
      locations = described_class.postgres_locations
      expect(locations.count { it.name == "hetzner-fsn1" }).to eq(1)
      expect(locations.find { it.name == "hetzner-fsn1" }.project_id).to be_nil
    end

    it "includes AWS public locations regardless of array (bypass preserved)" do
      expect(described_class[name: "us-east-1"].visible).to be(false)
      names_nil = described_class.postgres_locations.map(&:name)
      names_empty = described_class.postgres_locations([]).map(&:name)
      names_with_gcp = described_class.postgres_locations(["gcp-us-central1"]).map(&:name)
      expect([names_nil, names_empty, names_with_gcp]).to all(include("us-east-1", "us-west-2"))
    end
  end

  describe "gcp-us-east4 (seeded hidden Postgres location)" do
    subject(:east4) { described_class[name: "gcp-us-east4"] }

    it "is seeded as a hidden GCP location with the expected attributes" do
      expect(east4).not_to be_nil
      expect(east4.provider).to eq("gcp")
      expect(east4.visible).to be(false)
      expect(east4.display_name).to eq("us-east4")
      expect(east4.ui_name).to eq("Virginia, US (GCP)")
    end

    it "has billing rates for every Postgres family in the region (validate_billing_rate passes)" do
      ["standard-c4a-standard", "standard-c4a-highmem"].each do |family|
        expect { Validation.validate_billing_rate("PostgresVCpu", family, "gcp-us-east4") }.not_to raise_error
        expect { Validation.validate_billing_rate("PostgresStandbyVCpu", family, "gcp-us-east4") }.not_to raise_error
      end
      expect { Validation.validate_billing_rate("PostgresStorage", "standard", "gcp-us-east4") }.not_to raise_error
      expect { Validation.validate_billing_rate("PostgresStandbyStorage", "standard", "gcp-us-east4") }.not_to raise_error
    end

    it "has the VmVCpu rates the backing Postgres VM needs (no nil[\"id\"] crash on provisioning)" do
      ["c4a-standard", "c4a-highmem"].each do |family|
        expect(BillingRate.from_resource_properties("VmVCpu", family, "gcp-us-east4")).not_to be_nil
      end
    end

    it "stays hidden: excluded from VM listings and from postgres_locations unless flag-listed" do
      project_id = Project.create(name: "east4-vis-test").id
      expect(described_class.visible_or_for_project(project_id, []).select_order_map(:name)).not_to include("gcp-us-east4")
      expect(described_class.postgres_locations.map(&:name)).not_to include("gcp-us-east4")
      expect(described_class.postgres_locations(["gcp-us-east4"]).map(&:name)).to include("gcp-us-east4")
    end
  end

  it "#azs raises if not aws location" do
    p1_loc.update(provider: "hetzner")
    expect { p1_loc.azs }.to raise_error("azs is only valid for aws locations")
    expect(LocationAz.count).to eq(0)
  end

  it "#azs returns cached gcp azs" do
    gcp_loc = described_class.create(name: "gcp-azs-test", display_name: "gcp-azs-test", ui_name: "gcp-azs-test", visible: false, provider: "gcp")
    gcp_loc.add_location_az(az: "a")
    expect(gcp_loc.azs.map(&:az)).to eq(["a"])
  end

  it "returns the aws azs for an aws location" do
    p1_loc.add_location_az(az: "a", zone_id: "123")
    p1_loc.add_location_az(az: "b", zone_id: "456")
    expect(p1_loc.azs).to eq([LocationAz[az: "a"], LocationAz[az: "b"]])
  end

  it "fetches aws azs from aws if not present" do
    expect(p1_loc).to receive(:get_azs_from_aws).and_return([instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1a", zone_id: "123"), instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1b", zone_id: "456")])
    expect(p1_loc.azs).to eq([LocationAz[location_id: p1_loc.id, az: "a", zone_id: "123"], LocationAz[location_id: p1_loc.id, az: "b", zone_id: "456"]])
    expect(LocationAz.count).to eq(2)
  end

  it "raises descriptive error when AMI not found" do
    expect {
      p2_loc.pg_aws_ami("16", "x64")
    }.to raise_error("No AMI found for PostgreSQL 16 (x64) in l2")
  end

  it "#pg_gce_image returns image path using configured hosting project" do
    PgGceImage.dataset.destroy
    expect(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
    gcp_loc = described_class.create(name: "gcp-image-test", display_name: "gcp-image-test", ui_name: "gcp-image-test", visible: false, provider: "gcp")
    PgGceImage.create(gce_image_name: "postgres-ubuntu-2204-x64-20260218", arch: "x64", pg_versions: ["16", "17", "18"])
    expect(gcp_loc.pg_gce_image("x64", "17")).to eq("projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260218")
  end

  it "#pg_gce_image raises when no image found" do
    PgGceImage.dataset.destroy
    gcp_loc = described_class.create(name: "gcp-image-err", display_name: "gcp-image-err", ui_name: "gcp-image-err", visible: false, provider: "gcp")
    expect {
      gcp_loc.pg_gce_image("x64", "17")
    }.to raise_error("No GCE image found for arch x64 and pg_version 17")
  end

  describe "#scheduled_maintenance_events" do
    def event(not_before:, code: "system-reboot", description: "scheduled reboot")
      {code:, description:, not_before:, instance_event_id: "instance-event-1"}
    end

    def stub_client(events)
      client = Aws::EC2::Client.new(stub_responses: true, region: "us-west-2")
      client.stub_responses(:describe_instance_status, instance_statuses: [{instance_id: "i-0123456789abcdefg", events:}])
      expect(p2_loc.location_credential_aws).to receive(:client).and_return(client)
    end

    before do
      LocationCredentialAws.create_with_id(p2_loc.id, access_key: "k", secret_key: "s")
    end

    it "maps instances with pertinent events to the earliest not_before by vm id" do
      vm = create_vm(location_id: p2_loc.id)
      AwsInstance.create_with_id(vm, instance_id: "i-0123456789abcdefg")
      soonest = Time.now + 10 * 3600
      stub_client([event(not_before: soonest + 3600), event(not_before: soonest)])

      events = p2_loc.scheduled_maintenance_events
      expect(events.keys).to eq([vm.id])
      expect(events[vm.id]).to be_within(1).of(soonest)
    end

    it "ignores completed events" do
      stub_client([event(not_before: Time.now + 3600, description: "[Completed] reboot")])
      expect(p2_loc.scheduled_maintenance_events).to eq({})
    end

    it "ignores events whose code is not handled" do
      stub_client([event(not_before: Time.now + 3600, code: "unknown-event")])
      expect(p2_loc.scheduled_maintenance_events).to eq({})
    end

    it "returns empty for aws locations without a credential" do
      expect(p1_loc.location_credential_aws).to be_nil
      expect(p1_loc.scheduled_maintenance_events).to eq({})
    end

    it "returns empty for gcp locations" do
      expect(described_class[name: "gcp-us-central1"].scheduled_maintenance_events).to eq({})
    end

    it "returns empty for metal locations" do
      expect(described_class[name: "hetzner-fsn1"].scheduled_maintenance_events).to eq({})
    end
  end
end
