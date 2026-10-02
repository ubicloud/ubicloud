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

  describe ".needing_recert" do
    it "includes certs without expires_at created less than 60 days ago" do
      cert = create_cert(created_days_ago: 59)
      create_cert(created_days_ago: 61)
      expect(described_class.needing_recert.all).to eq [cert]
    end

    it "includes certs valid for more than 60 days expiring in more than 30 days" do
      cert = create_cert(created_days_ago: 58, expires_in_days: 31)
      create_cert(created_days_ago: 61, expires_in_days: 29)
      expect(described_class.needing_recert.all).to eq [cert]
    end

    it "includes certs valid for 60 days or less expiring in more than 15 days" do
      cert = create_cert(created_days_ago: 10, expires_in_days: 16)
      create_cert(created_days_ago: 30, expires_in_days: 14)
      expect(described_class.needing_recert.all).to eq [cert]
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
end
