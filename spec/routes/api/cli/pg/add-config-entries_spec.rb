# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-config-entries" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds/updated config entries" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.user_config).to eq({})
    expect(cli(%w[pg eu-central-h1/test-pg add-config-entries allow_in_place_tablespaces=on allow_alter_system=off])).to eq "Updated config:\nallow_alter_system=off\nallow_in_place_tablespaces=on\n"
    expect(pg.reload.user_config).to eq({"allow_in_place_tablespaces" => "on", "allow_alter_system" => "off"})
    expect(cli(%w[pg eu-central-h1/test-pg add-config-entries allow_system_table_mods=on allow_alter_system=on])).to eq "Updated config:\nallow_alter_system=on\nallow_in_place_tablespaces=on\nallow_system_table_mods=on\n"
    expect(pg.reload.user_config).to eq({"allow_in_place_tablespaces" => "on", "allow_alter_system" => "on", "allow_system_table_mods" => "on"})
  end
end
