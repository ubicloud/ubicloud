# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-pgbouncer-config-entries" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds/updated config entries" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.pgbouncer_user_config).to eq({})
    expect(cli(%w[pg eu-central-h1/test-pg add-pgbouncer-config-entries server_round_robin=1 disable_pqexec=1])).to eq "Updated pgbouncer config:\ndisable_pqexec=1\nserver_round_robin=1\n"
    expect(pg.reload.pgbouncer_user_config).to eq({"server_round_robin" => "1", "disable_pqexec" => "1"})
    expect(cli(%w[pg eu-central-h1/test-pg remove-pgbouncer-config-entries application_name_add_host disable_pqexec])).to eq "Updated pgbouncer config:\nserver_round_robin=1\n"
    expect(pg.reload.pgbouncer_user_config).to eq({"server_round_robin" => "1"})
  end
end
