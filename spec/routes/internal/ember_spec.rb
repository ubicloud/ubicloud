# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "internal ember api" do
  let(:host) { create_ember_host }
  let(:ember) do
    s = create_postgres_ember(state: "running", vm_host_id: host.id, slot: 3,
      ip6: "2a01:db8::3").ember
    Strand.create_with_id(s, prog: "Ember::Nexus", label: "wait")
    s.reload
  end

  describe "authentication" do
    it "refuses a request with no token" do
      get "/internal/ember/route?host=#{ember.ubid}.ember.test"
      expect(last_response.status).to eq(401)
    end

    it "refuses a token signed with the wrong secret" do
      header "Authorization", "Bearer #{JWT.encode({iss: "x"}, "not-the-secret", "HS256")}"
      get "/internal/ember/route?host=#{ember.ubid}.ember.test"
      expect(last_response.status).to eq(401)
    end

    it "refuses a malformed token" do
      header "Authorization", "Bearer not-a-jwt"
      get "/internal/ember/route?host=#{ember.ubid}.ember.test"
      expect(last_response.status).to eq(401)
    end

    it "refuses everything when no gateway secret is configured" do
      allow(Config).to receive(:postgres_gateway_token_secret).and_return(nil)
      header "Authorization", "Bearer anything"
      get "/internal/ember/route?host=#{ember.ubid}.ember.test"
      expect(last_response.status).to eq(401)
    end
  end

  describe "route lookup" do
    before { login_gateway }

    it "resolves an ember from the first label of the SNI name" do
      get "/internal/ember/route?host=#{ember.ubid}.pgc.ubicloud.app"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["ember_id"]).to eq(ember.ubid)
      expect(body["state"]).to eq("running")
      expect(body["target_ip6"]).to eq("2a01:db8::3")
      expect(body["port"]).to eq(5432)
      # The hop is encrypted below PostgreSQL, so no second TLS session.
      expect(body["upstream_tls"]).to be false
    end

    it "reports a paused ember as paused, with no address" do
      ember.update(state: "paused", ip6: nil)
      get "/internal/ember/route?host=#{ember.ubid}.ember.test"
      body = JSON.parse(last_response.body)
      expect(body["state"]).to eq("paused")
      expect(body["target_ip6"]).to be_nil
    end

    it "404s for a name that is not an ember id" do
      get "/internal/ember/route?host=not-a-ubid.ember.test"
      expect(last_response.status).to eq(404)
    end

    it "404s for a ubid of the wrong type" do
      get "/internal/ember/route?host=#{host.ubid}.ember.test"
      expect(last_response.status).to eq(404)
    end

    it "404s for an ember that does not exist" do
      get "/internal/ember/route?host=#{Ember.generate_ubid}.ember.test"
      expect(last_response.status).to eq(404)
    end

    it "does not route to an ember that is not a Postgres ember" do
      other = create_ember(state: "running")
      get "/internal/ember/route?host=#{other.ubid}.ember.test"
      expect(last_response.status).to eq(404)
    end

    it "404s for an empty label" do
      get "/internal/ember/route?host=.ember.test"
      expect(last_response.status).to eq(404)
    end

    it "rejects a request with no host" do
      get "/internal/ember/route"
      expect(last_response.status).to eq(400)
    end
  end

  describe "resume" do
    before { login_gateway }

    it "resumes and returns the new route" do
      expect(EmberOperations).to receive(:resume).with(ember) {
        ember.update(state: "running", ip6: "2a01:db8::9")
      }
      post "/internal/ember/#{ember.ubid}/resume"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["target_ip6"]).to eq("2a01:db8::9")
    end

    it "answers 503 when there is nowhere to put it, so the client retries" do
      expect(EmberOperations).to receive(:resume)
        .and_raise(EmberOperations::NoCapacity.new("no host"))
      post "/internal/ember/#{ember.ubid}/resume"
      expect(last_response.status).to eq(503)
    end

    it "answers 503 and asks for reconciliation when the host call fails" do
      expect(EmberOperations).to receive(:resume)
        .and_raise(ember_command_crash("timeout"))
      post "/internal/ember/#{ember.ubid}/resume"
      expect(last_response.status).to eq(503)
      expect(ember.reload.checkup_set?(cached: false)).to be true
    end

    it "404s for an ember that does not exist" do
      post "/internal/ember/#{Ember.generate_ubid}/resume"
      expect(last_response.status).to eq(404)
    end

    # The Postgres gateway has no business resuming any other kind of ember.
    it "404s for an ember that is not a Postgres ember" do
      other = create_ember(state: "paused")
      post "/internal/ember/#{other.ubid}/resume"
      expect(last_response.status).to eq(404)
    end
  end

  describe "activity" do
    before { login_gateway }

    it "moves last_activity_at forward" do
      ember.update(last_activity_at: Time.now - 600)
      at = Time.now.utc
      post "/internal/gateway/activity",
        [{ember_id: ember.ubid, last_activity_at: at.iso8601(6), connections: 2, bytes: 100}].to_json
      expect(last_response.status).to eq(200)
      expect(ember.reload.last_activity_at).to be_within(1).of(at)
    end

    it "never moves it backwards" do
      recent = Time.now
      ember.update(last_activity_at: recent)
      post "/internal/gateway/activity",
        [{ember_id: ember.ubid, last_activity_at: (recent - 3600).utc.iso8601}].to_json
      expect(last_response.status).to eq(200)
      expect(ember.reload.last_activity_at).to be_within(1).of(recent)
    end

    it "treats an unparseable timestamp as now" do
      ember.update(last_activity_at: Time.now - 600)
      post "/internal/gateway/activity",
        [{ember_id: ember.ubid, last_activity_at: "not a time"}].to_json
      expect(last_response.status).to eq(200)
      expect(ember.reload.last_activity_at).to be_within(5).of(Time.now)
    end

    it "ignores reports for ids it does not recognise" do
      post "/internal/gateway/activity",
        [{ember_id: "nonsense"}, {ember_id: host.ubid}, "not a hash"].to_json
      expect(last_response.status).to eq(200)
    end

    it "rejects an empty body" do
      post "/internal/gateway/activity", ""
      expect(last_response.status).to eq(400)
    end

    it "rejects a body that is not JSON" do
      post "/internal/gateway/activity", "{["
      expect(last_response.status).to eq(400)
    end

    it "tells the gateway which of its cached routes have gone stale" do
      paused = create_postgres_ember(project_id: ember.project_id, name: "paused-one", state: "paused")
      destroyed = Ember.generate_ubid.to_s
      post("/internal/gateway/activity", {
        "reports" => [],
        "cached" => ["#{ember.ubid}.ember.test", "#{paused.ubid}.ember.test", "#{destroyed}.ember.test", "junk"],
      }.to_json)
      expect(last_response.status).to eq(200)
      invalidate = JSON.parse(last_response.body)["invalidate"]
      # Running: keep. Paused and gone: throw away. Unparseable: not a route.
      expect(invalidate).to contain_exactly("#{paused.ubid}.ember.test", "#{destroyed}.ember.test")
    end

    it "asks for nothing back when the gateway sent no cached routes" do
      post("/internal/gateway/activity", {"reports" => []}.to_json)
      expect(JSON.parse(last_response.body)["invalidate"]).to eq([])
    end

    it "still accepts a bare array from a gateway that has not been upgraded" do
      post("/internal/gateway/activity", [{"ember_id" => ember.ubid}].to_json)
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["invalidate"]).to eq([])
    end

    it "rejects a body that is not an array" do
      post "/internal/gateway/activity", {ember_id: ember.ubid}.to_json
      expect(last_response.status).to eq(400)
    end
  end
end
