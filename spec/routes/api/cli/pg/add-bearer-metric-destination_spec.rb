# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-bearer-metric-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
  end

  let(:pg) { PostgresResource.first }

  it "adds a metric destination authenticating with a bearer token" do
    body = cli(%w[pg eu-central-h1/test-pg add-bearer-metric-destination https://baz.example.com my_token])
    md = pg.metric_destinations.first
    expect(body).to eq <<~END
      Metric destination added to PostgreSQL database.
      Current metric destinations:
        1: #{md.ubid}  authorization  https://baz.example.com
    END
    expect(md.username).to be_nil
    expect(md.password).to be_nil
    expect(md.options).to eq({"authorization" => {"type" => "Bearer", "credentials" => "my_token"}})
  end

  it "adds custom headers alongside the bearer token" do
    body = cli(%w[pg eu-central-h1/test-pg add-bearer-metric-destination https://baz.example.com my_token X-Scope-OrgID=tenant1])
    md = pg.metric_destinations.first
    expect(body).to eq <<~END
      Metric destination added to PostgreSQL database.
      Current metric destinations:
        1: #{md.ubid}  authorization,headers  https://baz.example.com
    END
    expect(md.options["headers"]).to eq({"X-Scope-OrgID" => "tenant1"})
  end

  it "fails for a header argument without an equal sign" do
    expect(cli(%w[pg eu-central-h1/test-pg add-bearer-metric-destination https://baz.example.com my_token nope], status: 400))
      .to start_with "! Invalid argument, does not include `=`: \"nope\"\n"
    expect(pg.metric_destinations_dataset).to be_empty
  end
end
