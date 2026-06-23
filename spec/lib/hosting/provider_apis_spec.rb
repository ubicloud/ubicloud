# frozen_string_literal: true

RSpec.describe Hosting::ProviderApis do
  let(:provider) {
    HostProvider.create do
      it.id = create_vm_host.id
      it.server_identifier = "123"
      it.provider_name = HostProvider::HETZNER_PROVIDER_NAME
    end
  }

  describe ".for" do
    it "builds the provider-specific api client" do
      expect(described_class.for(provider)).to be_a Hosting::HetznerApis
    end

    it "raises for an unknown provider" do
      provider.provider_name = "unknown"
      expect { described_class.for(provider) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end
end
