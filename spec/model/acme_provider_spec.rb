# frozen_string_literal: true

RSpec.describe AcmeProvider do
  def create_provider(name, **)
    described_class.create(
      name:,
      directory_url: "https://#{name}.example/d",
      email: "ops@example.com",
      kid: "#{name}-kid",
      key: "#{name}-key",
      **,
    )
  end

  it "stores an encrypted account key and parses it back" do
    key = Clec::Cert.ec_key
    account = described_class.new(key: key.to_der)
    expect(account.private_key).to be_a OpenSSL::PKey::EC
    expect(account.private_key.to_der).to eq key.to_der
  end

  describe ".for_attempt" do
    let(:fresh_cert) { Cert.create(hostname: "fresh.example.com") }

    it "selects enabled providers in descending priority order and rotates by attempt" do
      create_provider("b", priority: 1)
      create_provider("a", priority: 2)
      create_provider("c", priority: 1)
      create_provider("off", priority: 0)
      create_provider("negative", priority: -1)

      expect((0..4).map { described_class.for_attempt(fresh_cert, it).name }).to eq %w[a b c a b]
    end

    it "skips the certificate's current provider after a restart when an alternative exists" do
      a = create_provider("a", priority: 2)
      create_provider("b", priority: 1)
      pinned = Cert.create(hostname: "pinned.example.com", acme_provider_id: a.id)

      expect(described_class.for_attempt(pinned, 0).name).to eq "a"
      expect(described_class.for_attempt(pinned, 1).name).to eq "b"
      expect(described_class.for_attempt(pinned, 2).name).to eq "b"
    end

    it "does not skip when the current provider is the only candidate" do
      a = create_provider("a", priority: 1)
      pinned = Cert.create(hostname: "pinned.example.com", acme_provider_id: a.id)

      expect(described_class.for_attempt(pinned, 3).name).to eq "a"
    end

    it "falls back to a per-cert-account provider built from Config when no provider is enabled" do
      create_provider("off", priority: 0)
      expect(Config).to receive_messages(acme_email: "config@example.com", acme_directory: "https://config.example/d", acme_eab_kid: "config-kid", acme_eab_hmac_key: "config-hmac")

      provider = described_class.for_attempt(fresh_cert, 0)
      expect(provider).to be_new
      expect(provider.id).to be_nil
      expect(provider.per_cert_accounts).to be true
      expect(provider.values.slice(:email, :directory_url, :kid)).to eq(email: "config@example.com", directory_url: "https://config.example/d", kid: "config-kid")
      expect(provider.key).to eq "config-hmac"
    end
  end
end
