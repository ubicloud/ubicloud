# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UbiMcp, "catalog" do
  expected = %w[get_object_info get_postgres get_postgres_config get_postgres_logs get_postgres_metrics
    get_postgres_options list_postgres list_postgres_backups].freeze

  it "pins the tool names" do
    expect(UbiMcp::TOOLS.map(&:tool_name)).to eq expected
  end

  it "declares every tool consistently" do
    UbiMcp::TOOLS.each do |tool|
      expect(tool.tool_name).to match(/\A(get|list)_[a-z_]+\z/)
      expect(tool.name.split("::").last).to eq tool.tool_name.split("_").map(&:capitalize).join
      expect(tool.annotations.to_h).to eq({readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false})
      expect(tool.description).to be_a(String).and(satisfy { it.ascii_only? && (1..2048).cover?(it.length) })
      schema = tool.input_schema.to_h
      expect(schema[:type]).to eq "object"
      expect(schema[:additionalProperties]).to be false
      expect(schema.keys & %i[anyOf oneOf allOf]).to be_empty
      (schema[:properties] || {}).each_value { expect(it[:description]).to be_a(String) }
      expect(tool.method(:run).owner).to eq tool.singleton_class
    end
  end

  it "takes exactly the schema properties as keywords of run" do
    UbiMcp::TOOLS.each do |tool|
      schema = tool.input_schema.to_h
      adapter, *keywords = tool.method(:run).parameters
      expect(adapter.first).to eq :req
      expect(keywords.map(&:first) - [:key, :keyreq]).to be_empty
      expect(keywords.map(&:last)).to match_array schema[:properties].keys
      expect(keywords.filter_map { |type, name| name.to_s if type == :keyreq }).to match_array(schema[:required] || [])
    end
  end

  it "keeps the instructions template short and ASCII" do
    expect(UbiMcp::INSTRUCTIONS_TEMPLATE.length).to be <= 1900
    expect(UbiMcp::INSTRUCTIONS_TEMPLATE).to satisfy(&:ascii_only?)
  end
end
