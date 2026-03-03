# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg remove-cert-auth-user" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "removes a user from cert_auth_users" do
    @pg.update(cert_auth_users: ["myuser1", "myuser2"])
    expect(cli(%w[pg eu-central-h1/test-pg remove-cert-auth-user myuser1])).to eq <<~END
      Users using certificate authentication:
        1: myuser2
    END
    expect(@pg.reload.cert_auth_users).to eq(["myuser2"])
  end

  it "is a no-op when user is not in cert_auth_users" do
    expect(cli(%w[pg eu-central-h1/test-pg remove-cert-auth-user myuser])).to eq <<~END
      Users using certificate authentication:
      No users using certificate authentication.
    END
    expect(@pg.reload.cert_auth_users).to eq([])
  end
end
