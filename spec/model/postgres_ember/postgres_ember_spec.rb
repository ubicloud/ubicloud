# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PostgresEmber do
  let(:ember) { create_postgres_ember }

  it "generates cc-prefixed ubids" do
    expect(ember.ubid).to start_with("cc")
  end

  it "encrypts the superuser password at rest and round-trips it" do
    stored = DB[:postgres_ember].where(id: ember.id).get(:superuser_password)
    expect(stored).not_to eq("ember-secret")
    expect(ember.reload.superuser_password).to eq("ember-secret")
  end

  # The generic lifecycle is Ember's and is tested there; what is checked
  # here is that a PostgresEmber answers for its ember on the Postgres surface.
  it "answers for its ember" do
    ember.ember.update(state: "running")
    expect(ember).to be_running
    expect(ember.name).to eq(ember.ember.name)
    expect(ember.display_state).to eq("running")
  end

  it "asks its Postgres row what the guest needs" do
    expect(ember.ember.guest_config).to eq({"superuser_password" => "ember-secret", "database" => "postgres"})
  end

  describe "addressing" do
    it "is addressed by ubid under its project" do
      expect(ember.path).to eq("/postgres-ember/#{ember.ubid}")
    end
  end

  describe "#connection_string" do
    it "puts the ember id in the name, for the gateway to read from SNI" do
      expect(ember.connection_string("ember.test"))
        .to eq("postgres://postgres:#{ember.superuser_password}@#{ember.ubid}.ember.test:5432/postgres?sslmode=require")
    end

    it "escapes a password that would otherwise break the URI" do
      ember.update(superuser_password: "a/b@c")
      expect(ember.connection_string("ember.test")).to include("a%2Fb%40c")
    end

    it "dials the gateway's address where there is no wildcard DNS, still sending the name" do
      allow(Config).to receive(:postgres_gateway_address).and_return("188.40.176.54")
      expect(ember.connection_string("ember.test"))
        .to eq("postgres://postgres:#{ember.superuser_password}@#{ember.ubid}.ember.test:5432/postgres?sslmode=require&hostaddr=188.40.176.54")
    end

    it "takes a port with the address" do
      allow(Config).to receive(:postgres_gateway_address).and_return("188.40.176.54:6432")
      expect(ember.connection_string("ember.test")).to end_with(".ember.test:6432/postgres?sslmode=require&hostaddr=188.40.176.54")
    end

    it "takes an IPv6 gateway with its port" do
      allow(Config).to receive(:postgres_gateway_address).and_return("2a01:4f8::2:5432")
      expect(ember.connection_string("ember.test")).to end_with("&hostaddr=2a01:4f8::2")
    end
  end

  describe "claiming" do
    it "is unclaimed until it is claimed" do
      expect(ember).not_to be_claimed
      ember.update(claimed_at: Time.now)
      expect(ember).to be_claimed
    end

    it "matches a claim token against its stored hash" do
      token = "a-claim-token"
      ember.update(claim_token_digest: described_class.hash_claim_token(token))
      expect(ember.claim_token_matches?(token)).to be true
      expect(ember.claim_token_matches?("wrong")).to be false
    end

    it "matches nothing when there is no token to match" do
      expect(ember.claim_token_matches?("anything")).to be false
      ember.update(claim_token_digest: described_class.hash_claim_token("t"))
      expect(ember.claim_token_matches?(nil)).to be false
    end
  end

  describe "endpoints" do
    it "builds a connection string that requires TLS" do
      uri = URI(ember.connection_string("ember.test"))
      expect(uri.scheme).to eq("postgres")
      expect(uri.host).to eq("#{ember.ubid}.ember.test")
      expect(uri.port).to eq(5432)
      expect(uri.path).to eq("/postgres")
      expect(uri.query).to eq("sslmode=require")
      expect(uri.userinfo).to eq("postgres:ember-secret")
    end

    it "escapes a password that would otherwise break the URI" do
      ember.update(superuser_password: "p@ss word/!")
      expect(URI(ember.connection_string("ember.test")).userinfo).to eq("postgres:p%40ss%20word%2F%21")
    end
  end

  # A PostgresEmber shares its ember's key, so the ember cannot go while the
  # Postgres row is still there; the nexus destroys the ember and this goes
  # with it rather than the generic prog having to name a workload.
  it "goes when its ember is destroyed" do
    ember.ember.destroy
    expect(described_class[ember.id]).to be_nil
  end
end
