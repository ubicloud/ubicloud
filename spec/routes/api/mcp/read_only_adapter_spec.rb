# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UbiMcp::ReadOnlyAdapter do
  let(:adapter) do
    env = Rack::MockRequest.env_for("/mcp", "HTTP_HOST" => "api.ubicloud.com", "HTTP_AUTHORIZATION" => "Bearer pat-#{@pat.ubid}-#{@pat.key}")
    described_class.new(app: Clover, env:, project_id: @project.ubid)
  end

  it "sends GET requests" do
    vm = create_vm(project_id: @project.id)
    expect(adapter.get("vm")[:items].map { it[:id] }).to eq [vm.ubid]
  end

  it "raises for any other method before reaching Clover" do
    path = "location/eu-central-h1/vm/x"
    expect(Clover).not_to receive(:call)
    [
      ["POST", -> { adapter.post(path, {}) }],
      ["PATCH", -> { adapter.patch(path, {}) }],
      ["DELETE", -> { adapter.delete(path) }],
      ["DELETE", -> { Ubicloud::Adapter.instance_method(:delete).bind_call(adapter, path) }],
      ["PUT", -> { adapter.send(:call, "PUT", path) }],
    ].each do |method, request|
      expect(&request).to raise_error(ArgumentError, "read-only adapter cannot send #{method} requests")
    end
  end
end
