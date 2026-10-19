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

  let(:sa_creds) { instance_double(Google::Auth::ServiceAccountCredentials) }

  before do
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds) do |json_key_io:, scope:|
      expect(json_key_io.read).to eq location_credential_gcp.credentials_json
      expect(scope).to eq "https://www.googleapis.com/auth/cloud-platform"
      sa_creds
    end
  end

  it "encrypts credentials_json column" do
    expect(location_credential_gcp.class.instance_variable_get(:@column_encryption_metadata).keys).to include(:credentials_json)
  end

  it "returns a zones client" do
    client = instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::Zones::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.zones_client).to be(client)
    expect(location_credential_gcp.zones_client).to be(client)
  end

  it "returns a subnetworks client" do
    client = instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::Subnetworks::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.subnetworks_client).to be(client)
    expect(location_credential_gcp.subnetworks_client).to be(client)
  end

  it "returns a zone operations client" do
    client = instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.zone_operations_client).to be(client)
    expect(location_credential_gcp.zone_operations_client).to be(client)
  end

  it "returns a region operations client" do
    client = instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::RegionOperations::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.region_operations_client).to be(client)
    expect(location_credential_gcp.region_operations_client).to be(client)
  end

  it "returns a global operations client" do
    client = instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.global_operations_client).to be(client)
    expect(location_credential_gcp.global_operations_client).to be(client)
  end

  it "returns an addresses client" do
    client = instance_double(Google::Cloud::Compute::V1::Addresses::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::Addresses::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.addresses_client).to be(client)
    expect(location_credential_gcp.addresses_client).to be(client)
  end

  it "returns a compute client" do
    client = instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::Instances::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.compute_client).to be(client)
    expect(location_credential_gcp.compute_client).to be(client)
  end

  it "returns a network firewall policies client" do
    client = instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.network_firewall_policies_client).to be(client)
    expect(location_credential_gcp.network_firewall_policies_client).to be(client)
  end

  it "returns a CRM client" do
    crm = instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService)
    expect(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm)
    expect(crm).to receive(:authorization=).with(sa_creds)
    expect(location_credential_gcp.crm_client).to be(crm)
    expect(location_credential_gcp.crm_client).to be(crm)
  end

  it "returns a networks client" do
    client = instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client)
    config = double
    expect(config).to receive(:credentials=).with(sa_creds)
    expect(Google::Cloud::Compute::V1::Networks::Rest::Client).to receive(:new).and_yield(config).and_return(client)
    expect(location_credential_gcp.networks_client).to be(client)
    expect(location_credential_gcp.networks_client).to be(client)
  end

  it "returns a regional CRM client" do
    crm = instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService)
    expect(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm)
    expect(crm).to receive(:root_url=).with("https://us-central1-cloudresourcemanager.googleapis.com/")
    expect(crm).to receive(:authorization=).with(sa_creds)
    expect(location_credential_gcp.regional_crm_client("us-central1")).to be(crm)
    expect(location_credential_gcp.regional_crm_client("us-central1")).to be(crm)
  end

  it "returns a storage client" do
    client = instance_double(Google::Cloud::Storage::Project)
    expect(Google::Cloud::Storage).to receive(:new).with(
      project_id: "test-gcp-project",
      credentials: sa_creds,
    ).and_return(client)
    expect(location_credential_gcp.storage_client).to be(client)
    expect(location_credential_gcp.storage_client).to be(client)
  end

  it "returns an IAM client" do
    iam = instance_double(Google::Apis::IamV1::IamService)
    expect(Google::Apis::IamV1::IamService).to receive(:new).and_return(iam)
    expect(iam).to receive(:authorization=).with(sa_creds)
    expect(location_credential_gcp.iam_client).to be(iam)
    expect(location_credential_gcp.iam_client).to be(iam)
  end

  it "memoizes a single service account credentials object across clients" do
    crm = instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService)
    expect(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm)
    expect(crm).to receive(:authorization=).with(sa_creds)
    iam = instance_double(Google::Apis::IamV1::IamService)
    expect(Google::Apis::IamV1::IamService).to receive(:new).and_return(iam)
    expect(iam).to receive(:authorization=).with(sa_creds)
    location_credential_gcp.crm_client
    location_credential_gcp.iam_client
    expect(Google::Auth::ServiceAccountCredentials).to have_received(:make_creds).once
  end

  context "when credentials_json is nil" do
    subject(:location_credential_gcp) {
      described_class.create_with_id(location,
        project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
        credentials_json: nil)
    }

    let(:adc) { instance_double(Google::Auth::ServiceAccountCredentials) }
    let(:impersonated_creds) { instance_double(Google::Auth::ImpersonatedServiceAccountCredentials) }

    before do
      allow(Google::Auth).to receive(:get_application_default).with("https://www.googleapis.com/auth/cloud-platform").and_return(adc)
      allow(Google::Auth::ImpersonatedServiceAccountCredentials).to receive(:make_creds).with(
        source_credentials: adc,
        impersonation_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/test@test-gcp-project.iam.gserviceaccount.com:generateAccessToken",
        scope: ["https://www.googleapis.com/auth/cloud-platform"],
      ).and_return(impersonated_creds)
    end

    it "authenticates clients via ADC impersonation of the service account" do
      crm = instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService)
      expect(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm)
      expect(crm).to receive(:authorization=).with(impersonated_creds)
      expect(location_credential_gcp.crm_client).to be(crm)
      expect(Google::Auth::ServiceAccountCredentials).not_to have_received(:make_creds)
    end

    it "memoizes a single impersonated credentials object across clients" do
      client = instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client)
      config = double
      expect(config).to receive(:credentials=).with(impersonated_creds)
      expect(Google::Cloud::Compute::V1::Instances::Rest::Client).to receive(:new).and_yield(config).and_return(client)
      storage = instance_double(Google::Cloud::Storage::Project)
      expect(Google::Cloud::Storage).to receive(:new).with(project_id: "test-gcp-project", credentials: impersonated_creds).and_return(storage)
      expect(location_credential_gcp.compute_client).to be(client)
      expect(location_credential_gcp.storage_client).to be(storage)
      expect(Google::Auth::ImpersonatedServiceAccountCredentials).to have_received(:make_creds).once
      expect(Google::Auth).to have_received(:get_application_default).once
    end
  end

  describe "lockout clients" do
    subject(:location_credential_gcp) {
      described_class.create_with_id(location,
        project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
        credentials_json:)
    }

    let(:key) { OpenSSL::PKey::RSA.new(2048) }
    let(:key_json) {
      {
        type: "service_account", project_id: "test-gcp-project", private_key_id: "key-1", private_key: key.to_pem,
        client_email: "test@test-gcp-project.iam.gserviceaccount.com", client_id: "1",
        token_uri: "https://oauth2.googleapis.com/token",
      }.to_json
    }
    let(:credentials_json) { key_json }

    before do
      allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_call_original
    end

    it "gives every lockout RPC a short timeout" do
      compute = location_credential_gcp.lockout_compute_client
      expect(compute.configure.rpcs.get.timeout).to eq 2
      expect(compute.configure.rpcs.delete_network_interface.timeout).to eq 5
      expect(compute.configure.rpcs.reset.timeout).to eq 5
      expect(location_credential_gcp.lockout_compute_client).to be(compute)

      zone_operations = location_credential_gcp.lockout_zone_operations_client
      expect(zone_operations.configure.rpcs.get.timeout).to eq 2
      expect(location_credential_gcp.lockout_zone_operations_client).to be(zone_operations)

      policies = location_credential_gcp.lockout_network_firewall_policies_client
      expect(policies.configure.rpcs.get.timeout).to eq 2
      expect(policies.configure.rpcs.add_rule.timeout).to eq 5
      expect(location_credential_gcp.lockout_network_firewall_policies_client).to be(policies)

      global_operations = location_credential_gcp.lockout_global_operations_client
      expect(global_operations.configure.rpcs.get.timeout).to eq 2
      expect(location_credential_gcp.lockout_global_operations_client).to be(global_operations)
    end

    it "signs a JWT locally, on credentials that the other clients do not use" do
      creds = location_credential_gcp.lockout_compute_client.configure.credentials
      expect(location_credential_gcp.lockout_zone_operations_client.configure.credentials).to be(creds)
      expect(location_credential_gcp.lockout_network_firewall_policies_client.configure.credentials).to be(creds)
      expect(location_credential_gcp.lockout_global_operations_client.configure.credentials).to be(creds)
      shared = location_credential_gcp.compute_client.configure.credentials
      expect(shared).not_to be(creds)
      expect(shared.enable_self_signed_jwt?).to be false

      jwt = creds.apply({})[:authorization].delete_prefix("Bearer ")
      claims, = JWT.decode(jwt, key.public_key, true, algorithm: "RS256")
      expect(claims).to include(
        "iss" => "test@test-gcp-project.iam.gserviceaccount.com",
        "scope" => "https://www.googleapis.com/auth/cloud-platform",
      )
    end

    context "when credentials_json is nil" do
      let(:credentials_json) { nil }

      before do
        source = Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: StringIO.new(key_json), scope: "https://www.googleapis.com/auth/cloud-platform")
        allow(Google::Auth).to receive(:get_application_default).and_return(source)
        allow(Google::Auth::ImpersonatedServiceAccountCredentials).to receive(:make_creds).and_call_original
      end

      it "uses the shared impersonated credentials" do
        creds = location_credential_gcp.lockout_compute_client.configure.credentials
        expect(creds).to be_a(Google::Auth::ImpersonatedServiceAccountCredentials)
        expect(location_credential_gcp.lockout_zone_operations_client.configure.credentials).to be(creds)
        expect(location_credential_gcp.lockout_network_firewall_policies_client.configure.credentials).to be(creds)
        expect(location_credential_gcp.lockout_global_operations_client.configure.credentials).to be(creds)
        expect(location_credential_gcp.compute_client.configure.credentials).to be(creds)
      end
    end
  end
end
