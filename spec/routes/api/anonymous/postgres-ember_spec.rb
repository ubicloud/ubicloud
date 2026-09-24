# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "anonymous ember" do
  let(:service_project) { Project.create(name: "ember-service") }
  let(:ember) {
    pg_ember = create_postgres_ember(project_id: service_project.id)
    # Semaphores only insert where a strand with that id already exists.
    Strand.create_with_id(pg_ember, prog: "Ember::Nexus", label: "wait")
    pg_ember
  }

  before do
    allow(Config).to receive(:ember_service_project_id).and_return(service_project.id)
  end

  def authorize(token)
    header "Authorization", "Bearer #{token}"
  end

  it "refuses the whole surface when no service project is configured" do
    allow(Config).to receive(:ember_service_project_id).and_return(nil)
    post "/postgres-ember"
    expect(last_response.status).to eq(501)
  end

  it "answers 404 for anything else on the surface" do
    get "/postgres-ember"
    expect(last_response.status).to eq(404)
  end

  describe "create" do
    it "returns the ember, the token and a claim url" do
      expect(PostgresEmberOperations).to receive(:create) { |**args|
        expect(args[:project_id]).to eq(service_project.id)
        expect(args[:creator_ip]).to eq("127.0.0.1")
        expect(args[:claim_token]).not_to be_nil
        expect(args[:expires_at]).to be > Time.now
        ember
      }
      post "/postgres-ember", {pg_version: "18"}.to_json
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["id"]).to eq(ember.ubid)
      expect(body["password"]).to eq(ember.superuser_password)
      expect(body["claim_url"]).to include(body["token"])
    end

    it "stops an address that has had its allowance for the day" do
      allow(Config).to receive(:postgres_ember_anonymous_creates_per_ip_per_day).and_return(1)
      expect(PostgresEmberOperations).to receive(:create).and_return(ember)
      post "/postgres-ember"
      expect(last_response.status).to eq(201)

      post "/postgres-ember"
      expect(last_response.status).to eq(429)
    end

    it "starts a new window once the old one has run out" do
      allow(Config).to receive(:postgres_ember_anonymous_creates_per_ip_per_day).and_return(1)
      expect(PostgresEmberOperations).to receive(:create).twice.and_return(ember)
      post "/postgres-ember"
      PostgresEmberRateLimit.first.update(window_start: Time.now - 25 * 60 * 60)
      post "/postgres-ember"
      expect(last_response.status).to eq(201)
      expect(PostgresEmberRateLimit.first.count).to eq(1)
    end

    it "gives the attempt back when there is no capacity" do
      expect(PostgresEmberOperations).to receive(:create).and_raise(EmberOperations::NoCapacity.new("no template"))
      post "/postgres-ember"
      expect(last_response.status).to eq(503)
      expect(PostgresEmberRateLimit.first.count).to eq(0)
    end
  end

  describe "manage" do
    let(:token) { "token-that-was-handed-out" }

    before do
      ember.update(claim_token_digest: PostgresEmber.hash_claim_token(token))
    end

    it "needs the ember's own token" do
      get "/postgres-ember/#{ember.ubid}"
      expect(last_response.status).to eq(404)

      authorize("wrong")
      get "/postgres-ember/#{ember.ubid}"
      expect(last_response.status).to eq(404)
    end

    it "hides an ember that belongs to somebody's project" do
      ember.ember.update(project_id: Project.create(name: "someone-else").id)
      authorize(token)
      get "/postgres-ember/#{ember.ubid}"
      expect(last_response.status).to eq(404)
    end

    it "hides an ember that does not exist" do
      authorize(token)
      get "/postgres-ember/#{Ember.generate_ubid}"
      expect(last_response.status).to eq(404)
    end

    it "shows the ember with its credentials" do
      authorize(token)
      get "/postgres-ember/#{ember.ubid}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["connection_string"]).to include(ember.ubid)
    end

    it "pauses, resumes and resets the password" do
      authorize(token)
      post "/postgres-ember/#{ember.ubid}/pause"
      expect(last_response.status).to eq(200)
      expect(ember.reload.semaphores.map(&:name)).to include("pause")

      expect(EmberOperations).to receive(:resume)
      post "/postgres-ember/#{ember.ubid}/resume"
      expect(last_response.status).to eq(200)

      old = ember.superuser_password
      post "/postgres-ember/#{ember.ubid}/reset-password"
      expect(last_response.status).to eq(200)
      expect(ember.reload.superuser_password).not_to eq(old)
    end

    it "destroys the ember" do
      authorize(token)
      delete "/postgres-ember/#{ember.ubid}"
      expect(last_response.status).to eq(204)
      expect(ember.reload.semaphores.map(&:name)).to include("destroy")
    end
  end
end
