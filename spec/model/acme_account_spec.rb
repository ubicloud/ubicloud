# frozen_string_literal: true

RSpec.describe AcmeAccount do
  let(:provider) {
    AcmeProvider.create(name: "ca", directory_url: "https://ca.example/directory", priority: 0)
  }

  it "stores an encrypted account key and parses it back" do
    key = Clec::Cert.ec_key
    account = described_class.create(acme_provider_id: provider.id, account_key: key.to_der, kid: "test-kid")
    expect(account.acme_provider.id).to eq provider.id
    expect(account.private_key).to be_a OpenSSL::PKey::EC
    expect(account.private_key.to_der).to eq key.to_der
  end
end
