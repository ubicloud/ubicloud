# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-cert-auth-user" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "adds a user to cert_auth_users" do
    expect(@pg.cert_auth_users).to eq([])
    expect(cli(%w[pg eu-central-h1/test-pg add-cert-auth-user myuser])).to eq <<~END
      Users using certificate authentication:
        1: myuser
    END
    expect(@pg.reload.cert_auth_users).to eq(["myuser"])
  end

  it "does not add a user twice" do
    @pg.update(cert_auth_users: ["myuser"])
    expect(cli(%w[pg eu-central-h1/test-pg add-cert-auth-user myuser])).to eq <<~END
      Users using certificate authentication:
        1: myuser
    END
    expect(@pg.reload.cert_auth_users).to eq(["myuser"])
  end
end
