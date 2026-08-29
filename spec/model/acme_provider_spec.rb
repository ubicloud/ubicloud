# frozen_string_literal: true

RSpec.describe AcmeProvider do
  it "stores an encrypted account key and parses it back" do
    key = Clec::Cert.ec_key
    account = described_class.new(key: key.to_der)
    expect(account.private_key).to be_a OpenSSL::PKey::EC
    expect(account.private_key.to_der).to eq key.to_der
  end
end
