# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredentialGcp do
  subject(:location_credential_gcp) {
    described_class.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json:)
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

  let(:key_json) {
    {
      type: "service_account", project_id: "test-gcp-project", private_key_id: "key-1", private_key: OpenSSL::PKey::RSA.new(2048).to_pem,
      client_email: "test@test-gcp-project.iam.gserviceaccount.com", client_id: "1",
      token_uri: "https://oauth2.googleapis.com/token",
    }.to_json
  }
  let(:credentials_json) { key_json }
  let(:creds) { location_credential_gcp.compute_client.configure.credentials }

  before do
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_call_original
  end

  it "encrypts credentials_json column" do
    expect(location_credential_gcp.class.instance_variable_get(:@column_encryption_metadata).keys).to include(:credentials_json)
  end

  {
    zones_client: :Zones,
    subnetworks_client: :Subnetworks,
    zone_operations_client: :ZoneOperations,
    region_operations_client: :RegionOperations,
    global_operations_client: :GlobalOperations,
    addresses_client: :Addresses,
    compute_client: :Instances,
    network_firewall_policies_client: :NetworkFirewallPolicies,
    networks_client: :Networks,
  }.each do |method, service|
    it "returns a #{service} client with an 8 second timeout on every RPC" do
      client = location_credential_gcp.public_send(method)
      expect(client).to be_a(Google::Cloud::Compute::V1.const_get(service)::Rest::Client)
      expect(location_credential_gcp.public_send(method)).to be(client)
      expect(client.configure.credentials).to be(creds)
      rpcs = client.configure.rpcs
      expect(rpcs.class.instance_methods(false).map { rpcs.public_send(it).timeout }.uniq).to eq([8])
    end
  end

  {
    crm_client: Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService,
    iam_client: Google::Apis::IamV1::IamService,
  }.each do |method, service|
    it "returns a #{service.name.split("::").last} with 8 second open, send and read timeouts" do
      client = location_credential_gcp.public_send(method)
      expect(client).to be_a(service)
      expect(location_credential_gcp.public_send(method)).to be(client)
      expect(client.authorization).to be(creds)
      options = client.client_options
      expect([options.open_timeout_sec, options.send_timeout_sec, options.read_timeout_sec]).to eq([8, 8, 8])
    end
  end

  it "returns a regional CRM client with 8 second timeouts" do
    client = location_credential_gcp.regional_crm_client("us-central1")
    expect(client.root_url).to eq("https://us-central1-cloudresourcemanager.googleapis.com/")
    expect(location_credential_gcp.regional_crm_client("us-central1")).to be(client)
    expect(client.authorization).to be(creds)
    expect(client.client_options.read_timeout_sec).to eq(8)
  end

  it "returns a storage client with 8 second timeouts and a 20 second retry window" do
    client = location_credential_gcp.storage_client
    expect(client.project_id).to eq("test-gcp-project")
    expect(location_credential_gcp.storage_client).to be(client)
    service = client.service.service
    expect(service.authorization).to be(creds)
    expect([service.client_options.open_timeout_sec, service.client_options.send_timeout_sec, service.client_options.read_timeout_sec]).to eq([8, 8, 8])
    expect(service.request_options.max_elapsed_time).to eq(20)
  end

  it "fetches tokens through a connection with a 3 second timeout" do
    expect(creds).to be_a(Google::Auth::ServiceAccountCredentials)
    expect(Google::Auth::ServiceAccountCredentials).to have_received(:make_creds).with(hash_including(
      scope: "https://www.googleapis.com/auth/cloud-platform",
      default_connection: having_attributes(options: having_attributes(timeout: 3)),
    ))
  end

  it "memoizes a single service account credentials object across clients" do
    expect(location_credential_gcp.crm_client.authorization).to be(location_credential_gcp.iam_client.authorization)
    expect(Google::Auth::ServiceAccountCredentials).to have_received(:make_creds).once
  end

  context "when credentials_json is nil" do
    let(:credentials_json) { nil }
    let(:adc) { Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: StringIO.new(key_json), scope: "https://www.googleapis.com/auth/cloud-platform") }

    before do
      allow(Google::Auth).to receive(:get_application_default).with("https://www.googleapis.com/auth/cloud-platform").and_return(adc)
      allow(Google::Auth::ImpersonatedServiceAccountCredentials).to receive(:make_creds).and_call_original
    end

    it "authenticates clients via ADC impersonation of the service account" do
      expect(location_credential_gcp.crm_client.authorization).to be_a(Google::Auth::ImpersonatedServiceAccountCredentials)
      expect(Google::Auth::ImpersonatedServiceAccountCredentials).to have_received(:make_creds).with(
        source_credentials: adc,
        impersonation_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/test@test-gcp-project.iam.gserviceaccount.com:generateAccessToken",
        scope: ["https://www.googleapis.com/auth/cloud-platform"],
      )
    end

    it "memoizes a single impersonated credentials object across clients" do
      expect(location_credential_gcp.storage_client.service.service.authorization).to be(creds)
      expect(Google::Auth::ImpersonatedServiceAccountCredentials).to have_received(:make_creds).once
      expect(Google::Auth).to have_received(:get_application_default).once
    end
  end
end
