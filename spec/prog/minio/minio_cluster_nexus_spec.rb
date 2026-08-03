# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioClusterNexus do
  subject(:nx) {
    expect(Config).to receive(:minio_service_project_id).and_return(minio_project.id).at_least(:once)
    described_class.new(
      described_class.assemble(
        minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2",
      ),
    )
  }

  let(:minio_project) { Project.create(name: "default") }

  def make_publicly_signed(cluster)
    DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
    allow(Config).to receive_messages(acme_email: "test@ubicloud.com")
    cluster.update(root_cert_1: nil, root_cert_key_1: nil, root_cert_2: nil, root_cert_key_2: nil)
  end

  describe ".assemble" do
    before do
      allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
    end

    it "validates input" do
      expect {
        described_class.assemble(SecureRandom.uuid, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(minio_project.id, "minio/name", nil, "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error RuntimeError, "No existing location"

      expect {
        described_class.assemble(minio_project.id, "minio/name", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "mu", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: username"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 2, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: server_count"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 2, 2, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: drive_count"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 1, 2, 2, 4, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: storage_size_gib"
    end

    it "creates a minio cluster" do
      described_class.assemble(minio_project.id, "minio2", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")

      expect(MinioCluster.count).to eq 1
      expect(MinioCluster.first.name).to eq "minio2"
      expect(MinioCluster.first.location.name).to eq "hetzner-fsn1"
      expect(MinioCluster.first.admin_user).to eq "minio-admin"
      expect(MinioCluster.first.admin_password).to match(/^[A-Za-z0-9_-]{20}$/)
      expect(MinioCluster.first.storage_size_gib).to eq 100
      expect(MinioCluster.first.pools.count).to eq 1
      expect(MinioCluster.first.server_count).to eq 1
      expect(MinioCluster.first.drive_count).to eq 1
      expect(MinioCluster.first.pools.first.vm_size).to eq "standard-2"
      expect(MinioCluster.first.project).to eq minio_project
      expect(MinioCluster.first.strand.label).to eq "wait_certificates"
    end

    it "creates two self-signed root certificates when not using publicly signed certificates" do
      described_class.assemble(minio_project.id, "minio2", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")

      cluster = MinioCluster.first
      expect(cluster.root_cert_1).to be_a(String)
      expect(cluster.root_cert_2).to be_a(String)
      expect(cluster.uses_publicly_signed_certificates?).to be false
    end

    it "skips root certificates and starts a CertNexus strand when using publicly signed certificates" do
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      allow(Config).to receive_messages(acme_email: "test@ubicloud.com")

      described_class.assemble(minio_project.id, "minio2", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")

      cluster = MinioCluster.first
      expect(cluster.root_cert_1).to be_nil
      expect(cluster.root_cert_2).to be_nil
      expect(cluster.uses_publicly_signed_certificates?).to be true
      stack = cluster.strand.stack[0]
      expect(stack["initial_cert_id"]).to eq stack["current_cert_id"]
      cert = Cert.with_pk!(stack["initial_cert_id"])
      expect(cert.hostname).to eq "minio2.#{Config.minio_host_name}"
      expect(cert.strand.stack[0]["waiting_strand_id"]).to eq cluster.id
    end
  end

  describe "#wait_certificates" do
    it "hops to wait_pools for self-signed clusters" do
      expect { nx.wait_certificates }.to hop("wait_pools")
    end

    it "naps if the initial publicly signed cert is not ready" do
      make_publicly_signed(nx.minio_cluster)
      cert = Cert.create(hostname: nx.minio_cluster.hostname)
      refresh_frame(nx, new_values: {"initial_cert_id" => cert.id})
      expect { nx.wait_certificates }.to nap(600)
    end

    it "stores the publicly signed cert on the cluster and hops to wait_pools" do
      make_publicly_signed(nx.minio_cluster)
      cert, csr_key = Util.create_certificate(subject: "/CN=minio", duration: 60 * 60 * 24 * 30 * 3)
      cert_row = Cert.create(hostname: nx.minio_cluster.hostname, cert: cert.to_s, csr_key: csr_key.to_der)
      refresh_frame(nx, new_values: {"initial_cert_id" => cert_row.id})

      expect { nx.wait_certificates }.to hop("wait_pools")
      expect(nx.minio_cluster.server_cert).to eq cert.to_s
      expect(nx.minio_cluster.server_cert_key).to eq OpenSSL::PKey::EC.new(csr_key.to_der).to_pem
    end
  end

  describe "#wait_pools" do
    it "hops to wait if all pools are waiting" do
      # Pool strands start at "wait_servers", so need to set them to "wait"
      nx.minio_cluster.pools.each { it.strand.update(label: "wait") }
      expect { nx.wait_pools }.to hop("wait")
    end

    it "naps if not all pools are waiting" do
      # Pool strands start at "wait_servers", not "wait" - so it naps
      expect { nx.wait_pools }.to nap(5)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(60 * 60 * 24)
    end

    it "hops to reconfigure if reconfigure is set" do
      expect(nx).to receive(:when_reconfigure_set?).and_yield
      expect { nx.wait }.to hop("reconfigure")
    end

    it "hops to refresh_certificates if certificate_last_checked_at is before 1 month" do
      expect(nx.minio_cluster).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 30 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to refresh_certificates after 1 week for publicly signed clusters" do
      make_publicly_signed(nx.minio_cluster)
      nx.minio_cluster.update(certificate_last_checked_at: Time.now - 60 * 60 * 24 * 7 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to refresh_certificates if refresh_certificates semaphore is set" do
      nx.incr_refresh_certificates
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to switch_to_public_certs if the semaphore is set" do
      nx.incr_switch_to_public_certs
      expect { nx.wait }.to hop("switch_to_public_certs")
    end
  end

  describe "#switch_to_public_certs" do
    it "does nothing if the cluster is already publicly signed" do
      make_publicly_signed(nx.minio_cluster)
      expect { nx.switch_to_public_certs }.to hop("wait")
    end

    it "hops to wait without switching if ACME is not configured" do
      expect(Clog).to receive(:emit).with("Cannot switch minio cluster to publicly signed certificates: ACME or DNS zone not configured", {cannot_switch_minio_to_public_certs: {ubid: nx.minio_cluster.ubid}})
      expect { nx.switch_to_public_certs }.to hop("wait")
      expect(nx.minio_cluster.root_cert_1).not_to be_nil
      expect(nx.minio_cluster.server_cert).to be_nil
    end

    it "starts a CertNexus strand for the endpoint and hops to wait_switch_to_public_certs" do
      # Build the (self-signed) cluster before enabling ACME, so it is a
      # migration rather than a publicly assembled cluster.
      nx.minio_cluster
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      allow(Config).to receive_messages(acme_email: "test@ubicloud.com")

      expect { nx.switch_to_public_certs }.to hop("wait_switch_to_public_certs")
      cert = Cert.with_pk!(nx.strand.stack[0]["current_cert_id"])
      expect(cert.hostname).to eq nx.minio_cluster.hostname
      expect(cert.strand.stack[0]["waiting_strand_id"]).to eq nx.minio_cluster.id
    end
  end

  describe "#wait_switch_to_public_certs" do
    before do
      nx.minio_cluster
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      allow(Config).to receive_messages(acme_email: "test@ubicloud.com")
    end

    it "naps until the endpoint cert is ready" do
      cert_row = Cert.create(hostname: nx.minio_cluster.hostname)
      refresh_frame(nx, new_values: {"current_cert_id" => cert_row.id})
      expect { nx.wait_switch_to_public_certs }.to nap(600)
    end

    it "stores the endpoint cert, clears the roots, and triggers the servers" do
      cert, csr_key = Util.create_certificate(subject: "/CN=minio", duration: 60 * 60 * 24 * 30 * 3)
      cert_row = Cert.create(hostname: nx.minio_cluster.hostname, cert: cert.to_s, csr_key: csr_key.to_der)
      refresh_frame(nx, new_values: {"current_cert_id" => cert_row.id})
      server_ids = nx.minio_cluster.servers.map(&:id)

      expect { nx.wait_switch_to_public_certs }.to hop("wait")
      expect(nx.minio_cluster.reload.server_cert).to eq cert.to_s
      expect(nx.minio_cluster.root_cert_1).to be_nil
      expect(nx.minio_cluster.uses_publicly_signed_certificates?).to be true
      server_ids.each { expect(Semaphore.where(strand_id: it, name: "switch_to_public_certs").count).to eq(1) }
    end
  end

  describe "#refresh_certificates" do
    it "moves root_cert_2 to root_cert_1 and creates new root_cert_2 if root_cert_1 is about to expire, also updates server_cert" do
      rc2 = nx.minio_cluster.root_cert_2
      rck2 = nx.minio_cluster.root_cert_key_2
      certificate_last_checked_at = nx.minio_cluster.certificate_last_checked_at
      server_ids = nx.minio_cluster.servers.map(&:id)
      expect(OpenSSL::X509::Certificate).to receive(:new).with(nx.minio_cluster.root_cert_1).and_call_original
      expect(Time).to receive(:now).and_return(Time.now + 60 * 60 * 24 * 335 * 5 + 1).at_least(:once)
      expect(Util).to receive(:create_root_certificate).with(common_name: "#{nx.minio_cluster.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10).and_return(["cert", "key"])

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_cluster.root_cert_1).to eq rc2
      expect(nx.minio_cluster.root_cert_key_1).to eq rck2
      expect(nx.minio_cluster.root_cert_2).to eq "cert"
      expect(nx.minio_cluster.root_cert_key_2).to eq "key"
      expect(nx.minio_cluster.certificate_last_checked_at).to be > certificate_last_checked_at
      server_ids.each { expect(Semaphore.where(strand_id: it, name: "reconfigure").count).to eq(1) }
    end

    it "doesn't update root_certs if they are not close to expire" do
      rc1 = nx.minio_cluster.root_cert_1
      rck1 = nx.minio_cluster.root_cert_key_1
      rc2 = nx.minio_cluster.root_cert_2
      rck2 = nx.minio_cluster.root_cert_key_2
      certificate_last_checked_at = nx.minio_cluster.certificate_last_checked_at

      expect(OpenSSL::X509::Certificate).to receive(:new).with(nx.minio_cluster.root_cert_1).and_call_original

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_cluster.root_cert_1).to eq rc1
      expect(nx.minio_cluster.root_cert_key_1).to eq rck1
      expect(nx.minio_cluster.root_cert_2).to eq rc2
      expect(nx.minio_cluster.root_cert_key_2).to eq rck2
      expect(nx.minio_cluster.certificate_last_checked_at).to be > certificate_last_checked_at
    end
  end

  describe "#refresh_certificates", "with publicly signed certificates" do
    before do
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      allow(Config).to receive_messages(acme_email: "test@ubicloud.com")
      nx.minio_cluster.update(root_cert_1: nil, root_cert_key_1: nil, root_cert_2: nil, root_cert_key_2: nil)
    end

    it "does nothing but update last_checked_at if the cert is not close to expiration" do
      cert, key = Util.create_certificate(subject: "/CN=minio", duration: 60 * 60 * 24 * 30)
      nx.minio_cluster.update(server_cert: cert.to_pem, server_cert_key: key.to_pem)
      certificate_last_checked_at = nx.minio_cluster.certificate_last_checked_at

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_cluster.certificate_last_checked_at).to be > certificate_last_checked_at
    end

    it "starts a new CertNexus strand and hops to wait_refresh_public_cert if close to expiration" do
      cert, key = Util.create_certificate(subject: "/CN=minio", duration: 60 * 60 * 24 * 12)
      nx.minio_cluster.update(server_cert: cert.to_pem, server_cert_key: key.to_pem)

      expect { nx.refresh_certificates }.to hop("wait_refresh_public_cert")
      stack = nx.strand.stack[0]
      expect(stack["refresh_cert_id"]).to eq stack["current_cert_id"]
      new_cert = Cert.with_pk!(stack["refresh_cert_id"])
      expect(new_cert.hostname).to eq nx.minio_cluster.hostname
      expect(new_cert.strand.stack[0]["waiting_strand_id"]).to eq nx.minio_cluster.id
    end
  end

  describe "#wait_refresh_public_cert" do
    let(:cert) do
      Prog::Vnet::CertNexus.assemble(nx.minio_cluster.hostname, nx.minio_cluster.dns_zone.id).subject
    end

    before do
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      allow(Config).to receive_messages(acme_email: "test@ubicloud.com")
      nx.minio_cluster.update(root_cert_1: nil, root_cert_key_1: nil, root_cert_2: nil, root_cert_key_2: nil)
      refresh_frame(nx, new_values: {"refresh_cert_id" => cert.id})
    end

    it "naps if the cert is not ready" do
      expect { nx.wait_refresh_public_cert }.to nap(600)
    end

    it "stores the cert, reconfigures the servers (no restart), and hops to wait" do
      server_cert, server_cert_key = Util.create_certificate(subject: "/CN=minio", duration: 60 * 60 * 24 * 29)
      cert.update(cert: server_cert.to_pem, csr_key: server_cert_key.to_der)
      server_ids = nx.minio_cluster.servers.map(&:id)

      expect { nx.wait_refresh_public_cert }.to hop("wait")
      expect(nx.minio_cluster.reload.server_cert).to eq server_cert.to_pem
      server_ids.each do |id|
        expect(Semaphore.where(strand_id: id, name: "reconfigure").count).to eq(1)
        expect(Semaphore.where(strand_id: id, name: "restart").count).to eq(0)
      end
    end
  end

  describe "#reconfigure" do
    it "increments reconfigure semaphore of all minio servers and hops to wait" do
      expect(nx).to receive(:decr_reconfigure)
      server_ids = nx.minio_cluster.servers.map(&:id)
      expect { nx.reconfigure }.to hop("wait")
      server_ids.each do |id|
        expect(Semaphore.where(strand_id: id, name: "reconfigure").count).to eq(1)
        expect(Semaphore.where(strand_id: id, name: "restart").count).to eq(1)
      end
    end
  end

  describe "#destroy" do
    it "increments destroy semaphore of minio pools and hops to wait_pools_destroy" do
      expect(nx).to receive(:decr_destroy)
      pool_ids = nx.minio_cluster.pools.map(&:id)
      expect { nx.destroy }.to hop("wait_pools_destroyed")
      pool_ids.each { expect(Semaphore.where(strand_id: it, name: "destroy").count).to eq(1) }
    end
  end

  describe "#wait_pools_destroyed" do
    it "naps if there are still minio pools" do
      # Pool already exists from assemble
      expect { nx.wait_pools_destroyed }.to nap(10)
    end

    it "increments private subnet destroy and destroys minio cluster" do
      cluster_id = nx.minio_cluster.id
      # Capture references before deleting to avoid loading association into cache
      private_subnet = nx.minio_cluster.private_subnet
      private_subnet_id = private_subnet.id
      # Destroy servers first (FK constraint), then pools
      MinioServer.where(minio_pool_id: MinioPool.where(cluster_id:).select(:id)).destroy
      MinioPool.where(cluster_id:).destroy
      expect { nx.wait_pools_destroyed }.to exit({"msg" => "destroyed"})
      expect(private_subnet.firewalls_dataset.count).to eq 0
      expect(Semaphore.where(strand_id: private_subnet_id, name: "destroy").count).to eq(1)
    end

    it "destroys the publicly signed cert" do
      cluster_id = nx.minio_cluster.id
      dns_zone = DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      cert = Prog::Vnet::CertNexus.assemble(nx.minio_cluster.hostname, dns_zone.id).subject
      refresh_frame(nx, new_values: {"current_cert_id" => cert.id})
      MinioServer.where(minio_pool_id: MinioPool.where(cluster_id:).select(:id)).destroy
      MinioPool.where(cluster_id:).destroy

      expect { nx.wait_pools_destroyed }.to exit({"msg" => "destroyed"})
      expect(Semaphore.where(strand_id: cert.id, name: "destroy").count).to eq(1)
    end
  end
end
