# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredentialGcp do
  subject(:location_credential_gcp) {
    described_class.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: '{"type":"service_account","project_id":"test-gcp-project"}')
  }

  let(:location) {
    Location.create(
      name: "gcp-us-central1",
      display_name: "GCP US Central 1",
      ui_name: "gcp-us-central1",
      visible: true,
      provider: "gcp",
    )
  }

  it "parses credentials_json" do
    expect(location_credential_gcp.parsed_credentials).to eq({"type" => "service_account", "project_id" => "test-gcp-project"})
  end

  it "encrypts credentials_json column" do
    expect(location_credential_gcp.class.instance_variable_get(:@column_encryption_metadata).keys).to include(:credentials_json)
  end

  it "returns a zones client" do
    client = instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client)
    expect(Google::Cloud::Compute::V1::Zones::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.zones_client).to be(client)
  end

  it "returns a subnetworks client" do
    client = instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client)
    expect(Google::Cloud::Compute::V1::Subnetworks::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.subnetworks_client).to be(client)
  end

  it "returns a zone operations client" do
    client = instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client)
    expect(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.zone_operations_client).to be(client)
  end

  it "returns a region operations client" do
    client = instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client)
    expect(Google::Cloud::Compute::V1::RegionOperations::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.region_operations_client).to be(client)
  end

  it "returns a global operations client" do
    client = instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client)
    expect(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.global_operations_client).to be(client)
  end

  it "returns an addresses client" do
    client = instance_double(Google::Cloud::Compute::V1::Addresses::Rest::Client)
    expect(Google::Cloud::Compute::V1::Addresses::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.addresses_client).to be(client)
  end

  it "returns a compute client" do
    client = instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client)
    expect(Google::Cloud::Compute::V1::Instances::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.compute_client).to be(client)
  end

  it "returns a network firewall policies client" do
    client = instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client)
    expect(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.network_firewall_policies_client).to be(client)
  end

  it "returns a CRM client" do
    crm = instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService)
    expect(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm)
    sa_creds = instance_double(Google::Auth::ServiceAccountCredentials)
    expect(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(sa_creds)
    expect(crm).to receive(:authorization=).with(sa_creds)
    expect(location_credential_gcp.crm_client).to be(crm)
  end

  it "returns a networks client" do
    client = instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client)
    expect(Google::Cloud::Compute::V1::Networks::Rest::Client).to receive(:new).and_yield(double.as_null_object).and_return(client)
    expect(location_credential_gcp.networks_client).to be(client)
  end

  it "returns a regional CRM client" do
    crm = instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService)
    expect(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm)
    sa_creds = instance_double(Google::Auth::ServiceAccountCredentials)
    expect(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(sa_creds)
    expect(crm).to receive(:root_url=).with("https://us-central1-cloudresourcemanager.googleapis.com/")
    expect(crm).to receive(:authorization=).with(sa_creds)
    expect(location_credential_gcp.regional_crm_client("us-central1")).to be(crm)
  end

  it "returns a storage client" do
    client = instance_double(Google::Cloud::Storage::Project)
    expect(Google::Cloud::Storage).to receive(:new).with(
      project_id: "test-gcp-project",
      credentials: location_credential_gcp.parsed_credentials,
    ).and_return(client)
    expect(location_credential_gcp.storage_client).to be(client)
  end

  it "returns an IAM client" do
    iam = instance_double(Google::Apis::IamV1::IamService)
    expect(Google::Apis::IamV1::IamService).to receive(:new).and_return(iam)
    sa_creds = instance_double(Google::Auth::ServiceAccountCredentials)
    expect(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(sa_creds)
    expect(iam).to receive(:authorization=).with(sa_creds)
    expect(location_credential_gcp.iam_client).to be(iam)
  end
end
