# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg list" do
  id_headr = "id" + " " * 24

  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    @pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: @project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      desired_version: "17"
    ).subject
  end

  it "shows list of PostgreSQL databases" do
    expect(cli(%w[pg list -N])).to eq "eu-central-h1  test-pg  #{@pg.ubid}  17  standard\n"
  end

  it "-f option specifies fields" do
    expect(cli(%w[pg list -Nf id,name])).to eq "#{@pg.ubid}  test-pg\n"
  end

  it "-l option filters to specific location" do
    expect(cli(%w[pg list -Nleu-central-h1])).to eq "eu-central-h1  test-pg  #{@pg.ubid}  17  standard\n"
    expect(cli(%w[pg list -Nleu-north-h1])).to eq "\n"
  end

  it "headers are shown by default" do
    expect(cli(%w[pg list])).to eq <<~END
      location       name     #{id_headr}  version  flavor  
      eu-central-h1  test-pg  #{@pg.ubid}  17       standard
    END
  end

  it "handles case where header size is larger than largest column size" do
    @pg.update(name: "Abc")
    expect(cli(%w[pg list])).to eq <<~END
      location       name  #{id_headr}  version  flavor  
      eu-central-h1  Abc   #{@pg.ubid}  17       standard
    END
  end

  it "handles multiple options" do
    expect(cli(%w[pg list -Nflocation,name,id])).to eq "eu-central-h1  test-pg  #{@pg.ubid}\n"
    expect(cli(%w[pg list -flocation,name,id])).to eq <<~END
      location       name     #{id_headr}
      eu-central-h1  test-pg  #{@pg.ubid}
    END
  end

  it "shows error for empty fields" do
    expect(cli(%w[pg list -Nf] + [""], status: 400)).to start_with "! No fields given in pg list -f option\n"
  end

  it "shows error for duplicate fields" do
    expect(cli(%w[pg list -Nfid,id], status: 400)).to start_with "! Duplicate field(s) in pg list -f option\n"
  end

  it "shows error for invalid fields" do
    expect(cli(%w[pg list -Nffoo], status: 400)).to start_with "! Invalid field(s) given in pg list -f option: foo\n"
  end

  it "shows error for invalid location" do
    expect(cli(%w[pg list -Nleu-/-h1], status: 400)).to start_with "! Invalid location provided in pg list -l option\n"
  end
end
