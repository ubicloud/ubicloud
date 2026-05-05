# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Parseable::ParseableResourceNexus do
  subject(:nx) {
    described_class.new(
      described_class.assemble(project_id: parseable_project.id, name: "test-parseable", location_id: Location::HETZNER_FSN1_ID, admin_user: "admin", vm_size: "standard-2", storage_size_gib: 100),
    )
  }

  before do
    allow(Config).to receive_messages(parseable_service_project_id: parseable_project.id, minio_service_project_id: minio_service_project.id)
  end

  let(:parseable_project) { Project.create(name: "parseable-svc") }
  let(:minio_service_project) { Project.create(name: "minio-svc") }

  describe ".assemble" do
    it "fails if name is invalid" do
      expect {
        described_class.assemble(project_id: parseable_project.id, name: "bad/name", location_id: Location::HETZNER_FSN1_ID, admin_user: "admin", vm_size: "standard-2", storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed
    end

    it "creates a parseable resource with access_key and secret_key" do
      described_class.assemble(project_id: parseable_project.id, name: "test-parseable2", location_id: Location::HETZNER_FSN1_ID, admin_user: "admin", vm_size: "standard-2", storage_size_gib: 100)
      pr = ParseableResource.first(name: "test-parseable2")
      expect(pr.access_key).not_to be_nil
      expect(pr.secret_key).not_to be_nil
      expect(pr.access_key.length).to eq(32)
      expect(pr.secret_key.length).to eq(64)
    end

    it "creates root certs with different durations (5 and 10 years)" do
      described_class.assemble(project_id: parseable_project.id, name: "test-parseable4", location_id: Location::HETZNER_FSN1_ID, admin_user: "admin", vm_size: "standard-2", storage_size_gib: 100)
      pr = ParseableResource.first(name: "test-parseable4")
      cert1 = OpenSSL::X509::Certificate.new(pr.root_cert_1)
      cert2 = OpenSSL::X509::Certificate.new(pr.root_cert_2)
      expect(cert1.not_after).to be < cert2.not_after
    end

    it "starts at configure_blob_storage" do
      st = described_class.assemble(project_id: parseable_project.id, name: "test-parseable3", location_id: Location::HETZNER_FSN1_ID, admin_user: "admin", vm_size: "standard-2", storage_size_gib: 100)
      expect(st.label).to eq("configure_blob_storage")
    end

    it "sets firewall rules allowing SSH and port 8000" do
      st = described_class.assemble(project_id: parseable_project.id, name: "test-parseable5", location_id: Location::HETZNER_FSN1_ID, admin_user: "admin", vm_size: "standard-2", storage_size_gib: 100)
      pr = st.subject
      rules = pr.private_subnet.firewalls.first.firewall_rules
      cidrs = rules.map { it.cidr.to_s }
      expect(cidrs).to include("0.0.0.0/0", "::/0")
    end
  end

  describe "#configure_blob_storage" do
    let(:minio_cluster_st) {
      Prog::Minio::MinioClusterNexus.assemble(minio_service_project.id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
    }

    it "naps if no blob storage is found" do
      expect { nx.configure_blob_storage }.to nap(30)
    end

    it "naps if blob storage is not yet in wait state" do
      minio_cluster_st
      expect { nx.configure_blob_storage }.to nap(30)
    end

    it "sets up MinIO user/policy/bucket and hops to wait_servers when blob storage is ready" do
      minio_cluster_st
      minio_cluster_st.update(label: "wait")

      admin_client = instance_double(Minio::Client)
      blob_client = instance_double(Minio::Client)

      pr = nx.parseable_resource
      expect(pr).to receive_messages(blob_storage_admin_client: admin_client, blob_storage_client: blob_client)

      expect(admin_client).to receive(:admin_add_user).with(pr.access_key, pr.secret_key)
      expect(admin_client).to receive(:admin_policy_add).with(pr.ubid, pr.blob_storage_policy)
      expect(admin_client).to receive(:admin_policy_set).with(pr.ubid, pr.access_key)
      expect(blob_client).to receive(:create_bucket).with(pr.bucket_name)
      expect(blob_client).to receive(:set_lifecycle_policy).with(pr.bucket_name, pr.ubid, ParseableResource::LOG_BUCKET_EXPIRATION_DAYS)

      expect { nx.configure_blob_storage }.to hop("wait_servers")
    end
  end

  describe "#wait_servers" do
    it "hops to wait when all servers are in wait state" do
      expect { nx.wait_servers }.to hop("wait")
    end

    it "naps if a server is not yet in wait state" do
      Prog::Parseable::ParseableServerNexus.assemble(nx.parseable_resource)
      expect { nx.wait_servers }.to nap(10)
    end
  end

  describe "#wait" do
    before { nx.parseable_resource.strand.update(label: "wait") }

    it "naps for approximately one month" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end

    it "hops to refresh_certificates if certificate is old" do
      nx.parseable_resource.certificate_last_checked_at = Time.now - 60 * 60 * 24 * 31
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to reconfigure when semaphore is set" do
      nx.incr_reconfigure
      expect { nx.wait }.to hop("reconfigure")
    end
  end

  describe "#refresh_certificates" do
    before { nx.parseable_resource.strand.update(label: "refresh_certificates") }

    it "rotates certs when root_cert_1 is about to expire" do
      cert_pem, key_pem = Util.create_root_certificate(common_name: "expiring CA", duration: 60 * 60 * 24 * 30 * 4)
      pr = nx.parseable_resource
      pr.update(root_cert_1: cert_pem, root_cert_key_1: key_pem)

      expect { nx.refresh_certificates }.to hop("wait")
      pr.reload
      expect(pr.certificate_last_checked_at).to be_within(5).of(Time.now)
    end

    it "does not rotate certs when root_cert_1 is still valid long-term" do
      cert_pem, key_pem = Util.create_root_certificate(common_name: "valid CA", duration: 60 * 60 * 24 * 365 * 5)
      pr = nx.parseable_resource
      pr.update(root_cert_1: cert_pem, root_cert_key_1: key_pem)

      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#reconfigure" do
    before { nx.parseable_resource.strand.update(label: "reconfigure") }

    it "decrements reconfigure and hops to wait" do
      nx.incr_reconfigure
      expect { nx.reconfigure }.to hop("wait")
      expect(Semaphore.where(strand_id: nx.strand.id, name: "reconfigure").count).to eq(0)
    end
  end

  describe "#wait_servers_destroyed" do
    it "naps while servers still exist" do
      pr = nx.parseable_resource
      vm = create_vm
      ParseableServer.create(parseable_resource_id: pr.id, vm_id: vm.id)
      expect { nx.wait_servers_destroyed }.to nap(10)
    end

    it "destroys the parseable resource when all servers are gone" do
      pr_id = nx.parseable_resource.id
      expect { nx.wait_servers_destroyed }.to exit({"msg" => "destroyed"})
      expect(ParseableResource.count(id: pr_id)).to eq(0)
    end
  end

  describe "#destroy" do
    let(:minio_cluster) {
      MinioCluster.create(
        location_id: Location::HETZNER_FSN1_ID,
        name: "test-minio",
        admin_user: "minio-admin",
        admin_password: "minio-password",
        root_cert_1: "r1",
        root_cert_2: "r2",
        project_id: minio_service_project.id,
      )
    }

    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(minio_service_project.id)
    end

    it "cleans up MinIO user and policy before destroying" do
      minio_cluster
      pr = nx.parseable_resource
      admin_client = instance_double(Minio::Client)
      expect(pr).to receive(:blob_storage_admin_client).and_return(admin_client).at_least(:once)
      nx.decr_destroy

      expect(admin_client).to receive(:admin_remove_user).with(pr.access_key)
      expect(admin_client).to receive(:admin_policy_remove).with(pr.ubid)

      expect { nx.destroy }.to hop("wait_servers_destroyed")
    end

    it "continues destroying even if MinIO cleanup fails" do
      minio_cluster
      pr = nx.parseable_resource
      admin_client = instance_double(Minio::Client)
      expect(pr).to receive(:blob_storage_admin_client).and_return(admin_client).at_least(:once)
      nx.decr_destroy

      expect(admin_client).to receive(:admin_remove_user).and_raise("connection refused")
      expect(admin_client).not_to receive(:admin_policy_remove)

      expect { nx.destroy }.to hop("wait_servers_destroyed")
    end

    it "skips MinIO cleanup when no blob_storage is found" do
      nx.decr_destroy
      expect { nx.destroy }.to hop("wait_servers_destroyed")
    end

    it "destroys the named firewall" do
      pr = nx.parseable_resource
      nx.decr_destroy

      firewall = Firewall.first(name: "#{pr.ubid}-firewall")
      expect(firewall).not_to be_nil
      expect { nx.destroy }.to hop("wait_servers_destroyed")
      expect(Firewall[firewall.id]).to be_nil
    end

    it "proceeds without error when no firewall is found" do
      pr = nx.parseable_resource
      Firewall.first(name: "#{pr.ubid}-firewall")&.destroy
      nx.decr_destroy

      expect { nx.destroy }.to hop("wait_servers_destroyed")
    end
  end
end
