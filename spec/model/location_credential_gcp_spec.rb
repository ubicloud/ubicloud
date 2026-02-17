# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredentialGcp do
  subject(:location_credential_gcp) {
    described_class.create_with_id(location.id,
      project_id: "test-project",
      service_account_email: "test@test-project.iam.gserviceaccount.com",
      credentials_json: '{"type":"service_account","project_id":"test-project"}')
  }

  let(:location) {
    Location.create(
      name: "gcp-test-location",
      display_name: "test-location",
      ui_name: "Test Location (GCP)",
      visible: false,
      provider: "gcp"
    )
  }

  it "parses credentials JSON" do
    expect(location_credential_gcp.parsed_credentials).to eq(
      "type" => "service_account",
      "project_id" => "test-project"
    )
  end

  it "creates a compute client" do
    client = instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client)
    expect(Google::Cloud::Compute::V1::Instances::Rest::Client).to receive(:new).and_yield(
      instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client::Configuration).tap {
        expect(it).to receive(:credentials=).with(location_credential_gcp.parsed_credentials)
      }
    ).and_return(client)
    expect(location_credential_gcp.compute_client).to be(client)
  end

  it "creates a zones client" do
    client = instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client)
    expect(Google::Cloud::Compute::V1::Zones::Rest::Client).to receive(:new).and_yield(
      instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client::Configuration).tap {
        expect(it).to receive(:credentials=).with(location_credential_gcp.parsed_credentials)
      }
    ).and_return(client)
    expect(location_credential_gcp.zones_client).to be(client)
  end

  it "creates a storage client" do
    client = instance_double(Google::Cloud::Storage::Project)
    expect(Google::Cloud::Storage).to receive(:new).with(
      project_id: "test-project",
      credentials: {"type" => "service_account", "project_id" => "test-project"}
    ).and_return(client)
    expect(location_credential_gcp.storage_client).to be(client)
  end

  it "creates an IAM client" do
    creds = instance_double(Google::Auth::ServiceAccountCredentials)
    expect(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).with(
      json_key_io: an_instance_of(StringIO),
      scope: "https://www.googleapis.com/auth/cloud-platform"
    ).and_return(creds)

    client = location_credential_gcp.iam_client
    expect(client).to be_a(Google::Apis::IamV1::IamService)
    expect(client.authorization).to eq(creds)
  end

  it "is associated with a location" do
    location_credential_gcp
    expect(location.location_credential_gcp).to eq(location_credential_gcp)
    expect(location_credential_gcp.location).to eq(location)
  end
end
