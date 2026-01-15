# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg ca-certificates" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
  end

  it "prints the root certificates" do
    @pg.update(root_cert_1: "C1", root_cert_2: "C2")
    expect(cli(%w[pg eu-central-h1/test-pg ca-certificates])).to eq "C1\nC2\n"
  end
end
