# frozen_string_literal: true

RSpec.describe AcmeAccount do
  let(:provider) {
    AcmeProvider.create(name: "ca", directory_url: "https://ca.example/directory", priority: 0)
  }

  describe ".fetch_or_register" do
    it "returns the existing account without locking or registering" do
      account = described_class.create(acme_provider_id: provider.id, account_key: Clec::Cert.ec_key.to_der, kid: "existing-kid")
      expect(provider).not_to receive(:lock!)
      expect(described_class.fetch_or_register(provider).id).to eq account.id
    end

    it "registers under a provider row lock and persists the shared account" do
      expect(provider).to receive(:lock!).with(:no_key_update).and_call_original
      expect(provider).to receive(:register_account).with(kind_of(OpenSSL::PKey::EC)).and_return("new-kid")

      account = described_class.fetch_or_register(provider)
      expect(account.kid).to eq "new-kid"
      expect(account.acme_provider_id).to eq provider.id
      expect(account.private_key).to be_a OpenSSL::PKey::EC
    end

    it "does not register twice when losing the registration race" do
      expect(provider).to receive(:lock!).and_wrap_original do |original, *args|
        described_class.create(acme_provider_id: provider.id, account_key: Clec::Cert.ec_key.to_der, kid: "winner-kid")
        original.call(*args)
      end
      expect(provider).not_to receive(:register_account)
      expect(described_class.fetch_or_register(provider).kid).to eq "winner-kid"
    end
  end

  it "stores an encrypted account key and parses it back" do
    key = Clec::Cert.ec_key
    account = described_class.create(acme_provider_id: provider.id, account_key: key.to_der, kid: "test-kid")
    expect(account.acme_provider.id).to eq provider.id
    expect(account.private_key).to be_a OpenSSL::PKey::EC
    expect(account.private_key.to_der).to eq key.to_der
  end
end
