# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ps connect" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    cli(%w[ps eu-central-h1/test-ps2 create])
    @ps1, @ps2 = PrivateSubnet.order(:name).all
  end

  it "connects requested private subnet to this subnet by id" do
    expect(ConnectedSubnet.count).to eq 0
    expect(cli(%W[ps eu-central-h1/test-ps connect #{@ps2.ubid}])).to eq "Connected private subnet #{@ps2.ubid} to #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end

  it "connects requested private subnet to this subnet by name" do
    expect(ConnectedSubnet.count).to eq 0
    expect(cli(%W[ps eu-central-h1/test-ps connect eu-central-h1/test-ps2])).to eq "Connected private subnet eu-central-h1/test-ps2 to #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end

  it "connects requested postgres private subnet to this subnet by postgres resource id" do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    expect(ConnectedSubnet.count).to eq 0
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(cli(%W[ps eu-central-h1/test-ps connect -P #{pg.ubid}])).to eq "Connected PostgreSQL database private subnet #{pg.ubid} to #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end

  it "connects requested postgres private subnet to this subnet by postgres resource name" do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    expect(ConnectedSubnet.count).to eq 0
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    expect(cli(%W[ps eu-central-h1/test-ps connect -P test-pg])).to eq "Connected PostgreSQL database private subnet test-pg to #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end

  it "errors if given postgres id is not authorized" do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    SubjectTag[project_id: @project.id, name: "Admin"].remove_members(@pat.id)
    AccessControlEntry.create(project_id: @project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["PrivateSubnet:connect"])
    AccessControlEntry.create(project_id: @project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["Postgres:view"])
    expect(cli(%W[ps eu-central-h1/test-ps connect -P test-pg], status: 400)).to eq "! Unexpected response status: 400\nDetails: PostgreSQL database subnet to be connected not found\n"
    expect(ConnectedSubnet.count).to eq 0
  end
end
