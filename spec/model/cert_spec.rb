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
end
