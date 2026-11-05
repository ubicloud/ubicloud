# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Cert do
  let(:cert_pem) { Util.create_root_certificate(common_name: "test CA", duration: 60 * 60 * 24 * 30)[0] }

  describe "#before_save" do
    it "sets expires_at from the certificate when saving" do
      cert = described_class.create(hostname: "test.example.com", cert: cert_pem)
      expect(cert.expires_at).to be_within(5).of(Time.now + 60 * 60 * 24 * 30)
    end

    it "sets expires_at when the certificate is added after creation" do
      cert = described_class.create(hostname: "test.example.com")
      cert.update(cert: cert_pem)
      expect(cert.expires_at).to be_within(5).of(Time.now + 60 * 60 * 24 * 30)
    end

    it "does not override an explicitly set expires_at" do
      expires_at = Time.utc(2030, 1, 1)
      cert = described_class.create(hostname: "test.example.com", cert: cert_pem, expires_at:)
      expect(cert.reload.expires_at).to eq expires_at
    end

    it "leaves expires_at nil when there is no certificate" do
      expect(described_class.create(hostname: "test.example.com").reload.expires_at).to be_nil
    end

    it "leaves expires_at nil when the certificate cannot be parsed" do
      expect(described_class.create(hostname: "test.example.com", cert: "cert-data").reload.expires_at).to be_nil
    end
  end

  def create_cert(created_days_ago:, expires_in_days: nil)
    now = Time.now
    described_class.create(
      hostname: "test.example.com",
      created_at: now - created_days_ago * 60 * 60 * 24,
      expires_at: expires_in_days && now + expires_in_days * 60 * 60 * 24,
    )
  end

  describe ".fresh" do
    it "includes certs without expires_at created less than 60 days ago" do
      cert = create_cert(created_days_ago: 59)
      create_cert(created_days_ago: 61)
      expect(described_class.fresh.all).to eq [cert]
    end

    it "includes certs valid for more than 60 days expiring in more than 30 days" do
      cert = create_cert(created_days_ago: 58, expires_in_days: 31)
      create_cert(created_days_ago: 61, expires_in_days: 29)
      expect(described_class.fresh.all).to eq [cert]
    end

    it "includes certs valid for 60 days or less expiring in more than 15 days" do
      cert = create_cert(created_days_ago: 10, expires_in_days: 16)
      create_cert(created_days_ago: 30, expires_in_days: 14)
      expect(described_class.fresh.all).to eq [cert]
    end
  end

  describe ".active" do
    it "includes certs without expires_at created less than 90 days ago" do
      cert = create_cert(created_days_ago: 89)
      create_cert(created_days_ago: 91)
      expect(described_class.active.all).to eq [cert]
    end

    it "includes certs that have not expired" do
      cert = create_cert(created_days_ago: 100, expires_in_days: 1)
      create_cert(created_days_ago: 1, expires_in_days: -1)
      expect(described_class.active.all).to eq [cert]
    end
  end

  describe ".reissue_requested?" do
    it "is true only for an existing certificate with a reissue request" do
      stamped = described_class.create(hostname: "a.example.com", reissue_requested_at: Time.now)
      plain = described_class.create(hostname: "b.example.com")
      expect(described_class.reissue_requested?(stamped.id)).to be true
      expect(described_class.reissue_requested?(plain.id)).to be false
      expect(described_class.reissue_requested?(nil)).to be false
    end
  end

  describe ".request_replacement" do
    it "wakes the load balancers and the strands that hold the certificates" do
      project = Project.create(name: "test-prj")
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps")
      lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080, health_check_protocol: "https", cert_enabled: true).subject
      held = described_class.create(hostname: "held.example.com")
      other = described_class.create(hostname: "other.example.com")
      lb.add_cert(held)
      certless = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "certless-lb", src_port: 81, dst_port: 8081, health_check_protocol: "https", cert_enabled: false).subject
      certless.add_cert(held)
      holder = Strand.create(prog: "Minio::MinioServerNexus", label: "minio_restart",
        stack: [{"link" => ["Minio::MinioServerNexus", "wait"]}, {"current_cert_id" => held.id}])
      other_holder = Strand.create(prog: "Postgres::PostgresResourceNexus", label: "wait", stack: [{"current_cert_id" => other.id}])
      unrelated = Strand.create(prog: "Vnet::CertNexus", label: "wait", stack: [{"current_cert_id" => held.id}])
      expect(Prog::Vnet::MaintainPresignedLoadBalancerCerts).to receive(:schedule_strand)
      expect(Prog::Vnet::MaintainPresignedPostgresCerts).to receive(:schedule_strand)

      described_class.request_replacement([held.id])

      expect(lb.refresh_cert_set?(cached: false)).to be true
      expect(certless.refresh_cert_set?(cached: false)).to be false
      expect(Semaphore.where(name: "refresh_certificates").select_map(:strand_id)).to eq [holder.id]
      expect([other_holder, unrelated].map { Semaphore.where(strand_id: it.id).count }).to eq [0, 0]
    end
  end
end
