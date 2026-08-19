# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresInitScript do
  let(:project) { Project.create(name: "pg-init-script-test-project") }

  it "returns the init_script as UTF-8" do
    pg = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
    described_class.create_with_id(pg, init_script: "echo 'héllo'")

    init_script = described_class[pg.id].init_script
    expect(init_script.encoding).to eq Encoding::UTF_8
    expect(init_script).to eq "echo 'héllo'"
  end
end
