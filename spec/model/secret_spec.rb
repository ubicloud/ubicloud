# frozen_string_literal: true

RSpec.describe Secret do
  let(:project) { Project.create(name: "test") }
  let(:secret_store) { SecretStore.create(project_id: project.id, name: "my-store") }
  let(:secret) { described_class.create(secret_store_id: secret_store.id, key: "api-key", value: "s3cr3t-value") }

  it "has a ubid with the se prefix" do
    expect(secret.ubid).to start_with("se")
  end

  it "encrypts the value at rest but decrypts transparently" do
    secret
    raw = DB[:secret].where(id: secret.id).get(:value)
    expect(raw).not_to eq("s3cr3t-value")
    expect(described_class[secret.id].value).to eq("s3cr3t-value")
  end

  it "requires key and value" do
    s = described_class.new(secret_store_id: secret_store.id)
    expect(s.valid?).to be false
    expect(s.errors[:key]).not_to be_nil
    expect(s.errors[:value]).not_to be_nil
  end

  it "rejects invalid keys" do
    s = described_class.new(secret_store_id: secret_store.id, key: "bad key!", value: "v")
    expect(s.valid?).to be false
    expect(s.errors[:key]).not_to be_nil
  end

  it "accepts keys with dots, dashes and underscores" do
    s = described_class.new(secret_store_id: secret_store.id, key: "my.secret_key-1", value: "v")
    expect(s.valid?).to be true
  end
end
