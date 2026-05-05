# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ParseableResource do
  subject(:parseable_resource) {
    described_class.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-parseable",
      admin_user: "admin",
      admin_password: "dummy-password",
      root_cert_1: "root_cert_1",
      root_cert_key_1: "root_cert_key_1",
      root_cert_2: "root_cert_2",
      root_cert_key_2: "root_cert_key_2",
      access_key: "access-key-1234",
      secret_key: "secret-key-5678",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100,
      project_id: Project.create(name: "test").id,
    )
  }

  let(:parseable_service_project) { Project.create(name: "parseable-svc") }
  let(:minio_service_project) { Project.create(name: "minio-svc") }

  let(:minio_cluster) {
    MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-minio",
      admin_user: "minio-admin",
      admin_password: "minio-password",
      root_cert_1: "r1",
      root_cert_2: "r2",
      project_id: parseable_service_project.id,
    )
  }

  let(:minio_dns_zone) { DnsZone.create(project_id: parseable_service_project.id, name: "minio.example.com") }

  before do
    allow(Config).to receive_messages(parseable_service_project_id: parseable_service_project.id, minio_service_project_id: minio_service_project.id)
  end

  describe ".for_project_location" do
    it "returns the resource matching project_id and location" do
      found = described_class.for_project_location(project_id: parseable_resource.project_id, location_id: Location::HETZNER_FSN1_ID)
      expect(found).to eq(parseable_resource)
    end

    it "returns nil when no resource exists for the location" do
      expect(Config).to receive(:postgres_service_project_id).and_return(parseable_resource.project_id)
      other_location = Location.create(name: "eu-west-1", display_name: "eu-west-1", ui_name: "eu-west-1", visible: false, provider: "hetzner")
      expect(described_class.for_project_location(location_id: other_location.id)).to be_nil
    end

    it "falls back to parseable service project correctly" do
      expect(Config).to receive(:parseable_service_project_id).and_return(parseable_resource.project.id)
      expect(described_class.for_project_location(project_id: nil, location_id: Location::HETZNER_FSN1_ID)).to eq(parseable_resource)
    end
  end

  describe ".client_for_project_location" do
    it "returns a client with the override if configured" do
      expect(Config).to receive(:parseable_endpoint_override).and_return("https://parseable.example.com").at_least(:once)

      client = described_class.client_for_project_location(project_id: parseable_resource.project_id, location_id: Location::HETZNER_FSN1_ID)
      expect(client.instance_variable_get(:@endpoint)).to eq("https://parseable.example.com")
    end

    it "returns a nil client if no resource exists" do
      client = described_class.client_for_project_location(project_id: parseable_service_project.id, location_id: Location::HETZNER_FSN1_ID)
      expect(client).to be_nil
    end

    it "returns a nil client if no server exists" do
      client = described_class.client_for_project_location(project_id: parseable_resource.project_id, location_id: Location::HETZNER_FSN1_ID)
      expect(client).to be_nil
    end

    it "returns a client if a server exists" do
      vm = create_vm
      ParseableServer.create_with_id(ParseableServer.generate_ubid.to_uuid, parseable_resource_id: parseable_resource.id, vm_id: vm.id)

      client = described_class.client_for_project_location(project_id: parseable_resource.project_id, location_id: Location::HETZNER_FSN1_ID)
      expect(client).to be_a(Parseable::Client)
    end
  end

  describe "#bucket_name" do
    it "returns the ubid" do
      expect(parseable_resource.bucket_name).to eq(parseable_resource.ubid)
    end
  end

  describe "#root_certs" do
    it "joins both root certs with a newline" do
      expect(parseable_resource.root_certs).to eq("root_cert_1\nroot_cert_2")
    end

    it "returns nil when root_cert_1 is absent" do
      parseable_resource.update(root_cert_1: nil)
      expect(parseable_resource.root_certs).to be_nil
    end

    it "returns nil when root_cert_2 is absent" do
      parseable_resource.update(root_cert_2: nil)
      expect(parseable_resource.root_certs).to be_nil
    end
  end

  describe "#blob_storage_policy" do
    it "allows all S3 actions on the resource bucket" do
      policy = parseable_resource.blob_storage_policy
      expect(policy[:Version]).to eq("2012-10-17")
      statement = policy[:Statement].first
      expect(statement[:Effect]).to eq("Allow")
      expect(statement[:Action]).to eq(["s3:*"])
      expect(statement[:Resource]).to include(a_string_starting_with("arn:aws:s3:::#{parseable_resource.ubid}"))
    end
  end

  describe "#hostname" do
    it "combines name with the parseable host name config" do
      expect(Config).to receive(:parseable_host_name).and_return("logs.example.com")
      expect(parseable_resource.hostname).to eq("test-parseable.logs.example.com")
    end
  end

  describe "#dns_zone" do
    it "returns the DnsZone matching parseable_service_project_id and parseable_host_name" do
      dns_zone = DnsZone.create(project_id: parseable_resource.project_id, name: "logs.example.com")
      expect(Config).to receive_messages(parseable_service_project_id: parseable_resource.project_id, parseable_host_name: "logs.example.com")
      expect(parseable_resource.dns_zone).to eq(dns_zone)
    end

    it "returns nil when no matching DnsZone exists" do
      expect(Config).to receive_messages(parseable_service_project_id: parseable_resource.project_id, parseable_host_name: "logs.example.com")
      expect(parseable_resource.dns_zone).to be_nil
    end
  end

  describe "#blob_storage_endpoint" do
    it "returns the blob storage url if set" do
      expect(Config).to receive_messages(postgres_service_project_id: parseable_service_project.id, minio_service_project_id: parseable_service_project.id, minio_host_name: "minio.example.com")
      minio_cluster
      minio_dns_zone
      expect(parseable_resource.blob_storage_endpoint).to eq("https://test-minio.minio.example.com:9000")
    end

    it "samples from ip4_urls when url is nil" do
      expect(Config).to receive_messages(postgres_service_project_id: parseable_service_project.id, minio_service_project_id: parseable_service_project.id, minio_host_name: "minio.example.com")
      pool = MinioPool.create(cluster_id: minio_cluster.id, start_index: 0, server_count: 1, drive_count: 1, storage_size_gib: 100, vm_size: "standard-2")
      MinioServer.create(minio_pool_id: pool.id, vm_id: create_vm.id, index: 0)
      vm = parseable_resource.blob_storage.servers.first.vm
      vm_ip4 = vm.ip4_string
      expect(parseable_resource.blob_storage_endpoint).to eq("https://#{vm_ip4}:9000")
    end
  end

  describe "#blob_storage_client" do
    it "builds a Minio::Client with parseable credentials" do
      expect(Config).to receive_messages(postgres_service_project_id: parseable_service_project.id, minio_service_project_id: parseable_service_project.id, minio_host_name: "minio.example.com")
      minio_cluster
      minio_dns_zone
      expect(parseable_resource.blob_storage_client).to be_a(Minio::Client)
    end
  end

  describe "#blob_storage_admin_client" do
    it "builds a Minio::Client with admin credentials" do
      expect(Config).to receive_messages(postgres_service_project_id: parseable_service_project.id, minio_service_project_id: parseable_service_project.id, minio_host_name: "minio.example.com")
      minio_cluster
      minio_dns_zone
      expect(parseable_resource.blob_storage_admin_client).to be_a(Minio::Client)
    end
  end

  describe "#blob_storage" do
    let(:minio_cluster) {
      MinioCluster.create(
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-minio",
        admin_user: "minio-admin",
        admin_password: "minio-password",
        root_cert_1: "r1",
        root_cert_2: "r2",
        project_id: parseable_service_project.id,
      )
    }

    it "finds MinioCluster by postgres_service_project_id first" do
      expect(Config).to receive(:postgres_service_project_id).and_return(parseable_service_project.id).at_least(:once)
      minio_cluster
      MinioCluster.create(
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-minio-2",
        admin_user: "minio-admin",
        admin_password: "minio-password",
        root_cert_1: "r1",
        root_cert_2: "r2",
        project_id: minio_service_project.id,
      )
      expect(parseable_resource.blob_storage).to eq(minio_cluster)
    end

    it "finds MinioCluster by minio_service_project_id if it does not exist in the postgres project" do
      expect(Config).to receive_messages(postgres_service_project_id: Project.create(name: "test-project").id, minio_service_project_id: parseable_service_project.id)
      minio_cluster
      expect(parseable_resource.blob_storage).to eq(minio_cluster)
    end

    it "returns nil when no MinioCluster exists in the location" do
      expect(parseable_resource.blob_storage).to be_nil
    end
  end
end
