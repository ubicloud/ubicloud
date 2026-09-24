# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "project ember" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:location) { Location[display_name: TEST_LOCATION] }

  before { login_api }

  def ready_host(blank: 0)
    template = create_ember_template(location_id: location.id)
    host = make_gateway_reachable(create_ember_host)
    add_ember_blanks(host, blank)
    EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: host.id, state: "ready")
    on_ember_command { {"slot" => 1, "ip6" => "2a01:db8::1", "caught_up" => true} }
    host
  end

  # An explicit override of zero, rather than stubbing, so the quota path is
  # exercised the way it runs in production.
  def zero_ember_quota
    ProjectQuota.create(project_id: project.id,
      quota_id: ProjectQuota.default_quotas["PostgresEmberCount"]["id"], value: 0)
  end

  def a_ember(**args)
    s = create_postgres_ember(project_id: project.id, location_id: location.id, **args)
    Strand.create_with_id(s, prog: "Ember::Nexus", label: "wait")
    s.reload
  end

  describe "create" do
    it "creates a running ember and returns its credentials" do
      ready_host
      post "/project/#{project.ubid}/postgres-ember", {location: location.display_name}.to_json
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["state"]).to eq("running")
      expect(body["password"]).not_to be_empty
      expect(body["connection_string"]).to include("postgres://postgres:")
      expect(body["host"]).to eq("#{body["id"]}.#{Config.postgres_gateway_hostname_suffix}")
    end

    it "defaults the location when none is given" do
      ready_host
      post "/project/#{project.ubid}/postgres-ember", {}.to_json
      expect(last_response.status).to eq(201)
    end

    it "accepts a name, database and version" do
      ready_host
      post "/project/#{project.ubid}/postgres-ember",
        {location: location.display_name, name: "my-ember", database: "app", pg_version: "18"}.to_json
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq("my-ember")
      expect(body["database"]).to eq("app")
    end

    it "rejects an invalid name" do
      ready_host
      post "/project/#{project.ubid}/postgres-ember", {name: "Not A Name"}.to_json
      expect(last_response.status).to eq(400)
    end

    it "rejects a location the project cannot see" do
      post "/project/#{project.ubid}/postgres-ember", {location: "nowhere"}.to_json
      expect(last_response.status).to eq(400)
    end

    it "answers 503 rather than 500 when there is no capacity" do
      create_ember_template(location_id: location.id)
      post "/project/#{project.ubid}/postgres-ember", {location: location.display_name}.to_json
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "type")).to eq("NoCapacity")
    end

    it "refuses once the project is at its quota" do
      ready_host
      zero_ember_quota
      post "/project/#{project.ubid}/postgres-ember", {location: location.display_name}.to_json
      expect(last_response.status).to eq(400)
      expect(last_response.body).to include("Quota exceeded")
    end
  end

  describe "list and show" do
    it "lists the project's embers without leaking passwords" do
      a_ember(name: "one")
      get "/project/#{project.ubid}/postgres-ember"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["count"]).to eq(1)
      expect(body["items"].first).not_to have_key("password")
    end

    it "shows one by name, with credentials" do
      ember = a_ember(name: "one")
      get "/project/#{project.ubid}/postgres-ember/one"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["id"]).to eq(ember.ubid)
      expect(body["password"]).to eq(ember.superuser_password)
    end

    it "shows one by ubid" do
      ember = a_ember(name: "one")
      get "/project/#{project.ubid}/postgres-ember/#{ember.ubid}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq(ember.ubid)
    end

    it "404s for one that does not exist" do
      get "/project/#{project.ubid}/postgres-ember/nope"
      expect(last_response.status).to eq(404)
    end

    it "includes an expiry when the ember has one" do
      a_ember(name: "one", expires_at: Time.now + 3600)
      get "/project/#{project.ubid}/postgres-ember/one"
      expect(JSON.parse(last_response.body)["expires_at"]).not_to be_nil
    end
  end

  describe "actions" do
    it "pauses asynchronously" do
      ember = a_ember(name: "one", state: "running")
      post "/project/#{project.ubid}/postgres-ember/one/pause"
      expect(last_response.status).to eq(200)
      expect(ember.ember.reload.pause_set?(cached: false)).to be true
    end

    it "resumes synchronously" do
      ember = a_ember(name: "one", state: "paused")
      expect(EmberOperations).to receive(:resume).with(ember.ember)
      post "/project/#{project.ubid}/postgres-ember/one/resume"
      expect(last_response.status).to eq(200)
    end

    it "answers 503 when a resume has nowhere to go" do
      a_ember(name: "one", state: "paused")
      expect(EmberOperations).to receive(:resume).and_raise(EmberOperations::NoCapacity.new("full"))
      post "/project/#{project.ubid}/postgres-ember/one/resume"
      expect(last_response.status).to eq(503)
    end

    it "resets the password on a paused ember without touching a host" do
      ember = a_ember(name: "one", state: "paused")
      before_password = ember.superuser_password
      post "/project/#{project.ubid}/postgres-ember/one/reset-password"
      expect(last_response.status).to eq(200)
      expect(ember.reload.superuser_password).not_to eq(before_password)
    end

    it "pushes a new password to the host of a running ember" do
      host = create_ember_host
      ember = a_ember(name: "one", state: "running", vm_host_id: host.id)
      configured = []
      on_ember_command { |cmd, kw|
        configured << [cmd, kw[:ember], JSON.parse(kw[:stdin]).dig("guest", "superuser_password")]
        {"ok" => true}
      }
      post "/project/#{project.ubid}/postgres-ember/one/reset-password"
      expect(last_response.status).to eq(200)
      expect(configured).to eq([["configure", ember.ubid, ember.reload.superuser_password]])
      expect(JSON.parse(last_response.body)["password"]).to eq(ember.reload.superuser_password)
    end

    it "reports a failure to reach the host rather than pretending it worked" do
      host = create_ember_host
      ember = a_ember(name: "one", state: "running", vm_host_id: host.id)
      on_ember_command { raise ember_command_crash("down") }
      post "/project/#{project.ubid}/postgres-ember/one/reset-password"
      expect(last_response.status).to eq(503)
      expect(ember.reload.checkup_set?(cached: false)).to be true
    end
  end

  describe "delete" do
    it "asks the nexus to tear it down" do
      ember = a_ember(name: "one")
      delete "/project/#{project.ubid}/postgres-ember/one"
      expect(last_response.status).to eq(204)
      expect(ember.ember.reload.destroy_set?(cached: false)).to be true
    end
  end

  describe "claim" do
    let(:service_project) { Project.create(name: "ember-service") }

    before { allow(Config).to receive(:ember_service_project_id).and_return(service_project.id) }

    def unclaimed(token, **args)
      s = create_postgres_ember(project_id: service_project.id, location_id: location.id,
        name: "anon", state: "paused",
        claim_token_digest: PostgresEmber.hash_claim_token(token), **args)
      Strand.create_with_id(s, prog: "Ember::Nexus", label: "wait")
      s.reload
    end

    it "moves the ember and its volume into the project and keeps the password" do
      ember = unclaimed("tok", expires_at: Time.now + 3600)
      before_password = ember.superuser_password
      post "/project/#{project.ubid}/postgres-ember/claim", {claim_token: "tok"}.to_json
      expect(last_response.status).to eq(200)

      ember.reload
      expect(ember.project_id).to eq(project.id)
      expect(ember.detachable_volume.reload.project_id).to eq(project.id)
      expect(ember.claimed_at).not_to be_nil
      expect(ember.expires_at).to be_nil
      # Single use: the digest is gone. The password is not, so the connection
      # string the ember was created with keeps working.
      expect(ember.claim_token_digest).to be_nil
      expect(ember.superuser_password).to eq(before_password)
    end

    it "404s for a token that matches nothing" do
      unclaimed("tok")
      post "/project/#{project.ubid}/postgres-ember/claim", {claim_token: "wrong"}.to_json
      expect(last_response.status).to eq(404)
    end

    it "410s for an ember that already expired" do
      unclaimed("tok", expires_at: Time.now - 1)
      post "/project/#{project.ubid}/postgres-ember/claim", {claim_token: "tok"}.to_json
      expect(last_response.status).to eq(410)
    end

    it "refuses once the project is at its quota" do
      unclaimed("tok")
      zero_ember_quota
      post "/project/#{project.ubid}/postgres-ember/claim", {claim_token: "tok"}.to_json
      expect(last_response.status).to eq(400)
    end

    it "requires a non-empty token" do
      post "/project/#{project.ubid}/postgres-ember/claim", {claim_token: ""}.to_json
      expect(last_response.status).to eq(400)
    end
  end

  it "does nothing for an action it does not know, rather than guessing" do
    # The routes only ever pass one of the three, but the case has an else and
    # it should be inert.
    ember = create_postgres_ember(project_id: project.id, name: "one")
    expect { postgres_ember_action_for(ember, "levitate") }.not_to raise_error
    expect(ember.reload.semaphores).to be_empty
  end

  def postgres_ember_action_for(ember, action)
    Clover.new({}).send(:postgres_ember_action, ember, action)
  end
end
