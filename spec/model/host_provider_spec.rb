# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe HostProvider do
  subject(:provider) {
    described_class.create do
      it.id = create_vm_host.id
      it.server_identifier = "123"
      it.provider_name = HostProvider::HETZNER_PROVIDER_NAME
    end
  }

  describe "api" do
    it "returns the api" do
      expect(provider.api).to be_a Hosting::HetznerApis
    end

    it "raises for an unknown provider" do
      provider.provider_name = "unknown"
      expect { provider.api }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end
end
