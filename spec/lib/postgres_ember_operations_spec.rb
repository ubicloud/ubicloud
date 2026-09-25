# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe PostgresEmberOperations do
  let(:project) { Project.create(name: "pg-ember-ops") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:template) { create_ember_template }
  let(:host) { create_ember_host }

  before do
    EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: host.id, state: "ready")
    make_gateway_reachable(host)
  end

  def started
    {"slot" => 3, "ip6" => "2a01:db8::3", "caught_up" => true}
  end

  it "creates a running ember with a database on it, and hands back the Postgres side" do
    on_ember_command { started }
    pg = described_class.create(project_id: project.id, location:, database: "app")

    expect(pg).to be_a(PostgresEmber)
    expect(pg.ember.state).to eq("running")
    expect(pg.database_name).to eq("app")
    expect(pg.pg_version).to eq("18")
    expect(pg.superuser_password).not_to be_empty
  end

  # The host takes the guest configuration as an opaque blob; this is what makes
  # an ember's guest a database.
  it "sends the credentials to the guest" do
    on_ember_command { |_, kw|
      payload = JSON.parse(kw[:stdin])
      expect(payload["guest"]["database"]).to eq("app")
      expect(payload["guest"]["superuser_password"]).not_to be_empty
      started
    }
    described_class.create(project_id: project.id, location:, database: "app")
  end

  it "records a claim token as a digest, never in the clear" do
    on_ember_command { started }
    pg = described_class.create(project_id: project.id, location:, claim_token: "secret-token")
    expect(pg.claim_token_digest).not_to eq("secret-token")
    expect(pg.claim_token_matches?("secret-token")).to be true
  end

  it "only restores a template for the version asked for" do
    expect { described_class.create(project_id: project.id, location:, pg_version: "17") }
      .to raise_error(EmberOperations::NoCapacity, /no ready postgres 17 template/)
  end
end
