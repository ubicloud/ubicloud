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

    it "creates a firewalls client" do
      client = instance_double(Google::Cloud::Compute::V1::Firewalls::Rest::Client)
      expect(Google::Cloud::Compute::V1::Firewalls::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::Firewalls::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.firewalls_client).to be(client)
    end

    it "creates a network_firewall_policies client" do
      client = instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client)
      expect(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.network_firewall_policies_client).to be(client)
    end

    it "creates an addresses client" do
      client = instance_double(Google::Cloud::Compute::V1::Addresses::Rest::Client)
      expect(Google::Cloud::Compute::V1::Addresses::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::Addresses::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.addresses_client).to be(client)
    end

    it "creates a zone_operations client" do
      client = instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client)
      expect(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.zone_operations_client).to be(client)
    end

    it "creates a region_operations client" do
      client = instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client)
      expect(Google::Cloud::Compute::V1::RegionOperations::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.region_operations_client).to be(client)
    end

    it "creates a global_operations client" do
      client = instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client)
      expect(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client).to receive(:new).and_yield(
        instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client::Configuration).tap {
          expect(it).to receive(:credentials=).with(location_credential.parsed_credentials)
        }
      ).and_return(client)
      expect(location_credential.global_operations_client).to be(client)
    end

    it "is associated with a location" do
      location_credential
      expect(location.location_credential).to eq(location_credential)
      expect(location_credential.location).to eq(location)
    end
  end

  context "with AWS access key credentials" do
    subject(:location_credential) {
      described_class.create_with_id(location.id,
        access_key: "AKIAIOSFODNN7EXAMPLE",
        secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    }

    let(:location) {
      Location.create(
        name: "us-east-1",
        display_name: "US East 1",
        ui_name: "US East 1",
        visible: true,
        provider: "aws"
      )
    }

    it "uses Aws::Credentials when access_key and secret_key are set" do
      creds = location_credential.credentials
      expect(creds).to be_a(Aws::Credentials)
    end

    it "returns an EC2 client" do
      ec2 = instance_double(Aws::EC2::Client)
      expect(Aws::EC2::Client).to receive(:new).and_return(ec2)
      expect(location_credential.client).to be(ec2)
    end

    it "returns an AWS IAM client when credentials_json is not set" do
      iam = instance_double(Aws::IAM::Client)
      expect(Aws::IAM::Client).to receive(:new).and_return(iam)
      expect(location_credential.iam_client).to be(iam)
    end
  end
end
