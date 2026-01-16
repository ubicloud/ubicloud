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
    expect(cli(%w[pg eu-central-h1/test-pg add-config-entries allow_in_place_tablespaces=on array_nulls=off])).to eq "Updated config:\nallow_in_place_tablespaces=on\narray_nulls=off\n"
    expect(pg.reload.user_config).to eq({"allow_in_place_tablespaces" => "on", "array_nulls" => "off"})
    expect(cli(%w[pg eu-central-h1/test-pg add-config-entries allow_system_table_mods=on array_nulls=on])).to eq "Updated config:\nallow_in_place_tablespaces=on\nallow_system_table_mods=on\narray_nulls=on\n"
    expect(pg.reload.user_config).to eq({"allow_in_place_tablespaces" => "on", "array_nulls" => "on", "allow_system_table_mods" => "on"})
  end
end
