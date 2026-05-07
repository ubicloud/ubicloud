# frozen_string_literal: true

require "yaml"

# rubocop:disable RSpec/DescribeClass
# There is no class in this case; the spec verifies a static config file.
RSpec.describe "config/postgres_exporter_queries.yml" do
  # rubocop:enable RSpec/DescribeClass
  it "parses as YAML" do
    expect { YAML.safe_load_file("config/postgres_exporter_queries.yml") }.not_to raise_error
  end

  it "is a non-empty mapping (top-level keys are query names)" do
    parsed = YAML.safe_load_file("config/postgres_exporter_queries.yml")
    expect(parsed).to be_a(Hash)
    expect(parsed).not_to be_empty
  end
end
