# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LocationCredential do
  context "with AWS credentials" do
    subject(:location_credential) {
      described_class.create_with_id(location.id, assume_role: "assume-role")
    }

    let(:location) {
      Location.create(
        name: "test-location",
        display_name: "display-name",
        ui_name: "ui-name",
        visible: true,
        provider: "aws"
      )
    }

    it "uses Aws::AssumeRoleCredentials when assume_role set" do
      creds = instance_double(Aws::AssumeRoleCredentials)
      expect(Aws::AssumeRoleCredentials).to receive(:new).with(role_arn: "assume-role", role_session_name: Config.aws_role_session_name).and_return(creds)
      expect(location_credential.credentials).to be(creds)
    end

    it "gets account id from sts" do
      sts_client = Aws::STS::Client.new(stub_responses: true)
      expect(Aws::STS::Client).to receive(:new).and_return(sts_client).at_least(:once)
      sts_client.stub_responses(:get_caller_identity, {account: "account-id"})
      expect(location_credential.aws_iam_account_id).to eq("account-id")
    end

    it "returns AWS IAM client for iam_client" do
      creds = instance_double(Aws::AssumeRoleCredentials)
      expect(Aws::AssumeRoleCredentials).to receive(:new).and_return(creds)
      iam = instance_double(Aws::IAM::Client)
      expect(Aws::IAM::Client).to receive(:new).with(region: "test-location", credentials: creds).and_return(iam)
      expect(location_credential.iam_client).to be(iam)
    end
  end

  context "with GCP credentials" do
    subject(:location_credential) {
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
      expect(location_credential.parsed_credentials).to eq(
        "type" => "service_account",
        "project_id" => "test-project"
      )
    end

    it "creates a compute client" do
      client = instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client)
      expect(Google::Cloud::Compute::V1::Instances::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.compute_client).to be(client)
    end

    it "creates a zones client" do
      client = instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client)
      expect(Google::Cloud::Compute::V1::Zones::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.zones_client).to be(client)
    end

    it "creates a storage client" do
      client = instance_double(Google::Cloud::Storage::Project)
      expect(Google::Cloud::Storage).to receive(:new).with(
        project_id: "test-project",
        credentials: {"type" => "service_account", "project_id" => "test-project"}
      ).and_return(client)
      expect(location_credential.storage_client).to be(client)
    end

    it "creates an IAM client" do
      creds = instance_double(Google::Auth::ServiceAccountCredentials)
      expect(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).with(
        json_key_io: an_instance_of(StringIO),
        scope: "https://www.googleapis.com/auth/cloud-platform"
      ).and_return(creds)

      client = location_credential.iam_client
      expect(client).to be_a(Google::Apis::IamV1::IamService)
      expect(client.authorization).to eq(creds)
    end

    it "creates a networks client" do
      client = instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client)
      expect(Google::Cloud::Compute::V1::Networks::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.networks_client).to be(client)
    end

    it "creates a subnetworks client" do
      client = instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client)
      expect(Google::Cloud::Compute::V1::Subnetworks::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.subnetworks_client).to be(client)
    end

    it "is associated with a location" do
      location_credential
      expect(location.location_credential).to eq(location_credential)
      expect(location_credential.location).to eq(location)
    end
  end
end
