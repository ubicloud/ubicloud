# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp project tools" do
  describe "get_object_info" do
    let(:vm) { create_vm(project_id: @project.id) }
    let(:info) { {"type" => "vm", "location" => "eu-central-h1", "name" => "test-vm"} }

    it "resolves an id to its type, location and name" do
      result = mcp_tool("get_object_info", id: vm.ubid)
      expect(result).to eq({
        "content" => [{"type" => "text", "text" => info.to_json}],
        "isError" => false,
        "structuredContent" => info,
      })
    end

    it "works with a token restricted to Vm:view" do
      restrict_pat_to("Vm:view")
      expect(mcp_tool_data("get_object_info", id: vm.ubid)).to eq info
    end

    it "returns ResourceNotFound when the token lacks the view permission" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_object_info", id: vm.ubid)).to start_with "ResourceNotFound: "
    end

    it "returns ResourceNotFound for an unknown id" do
      expect(mcp_tool_error("get_object_info", id: "vm345678901234567890123456")).to start_with "ResourceNotFound: "
    end

    it "rejects a malformed id or the id of an unsupported type before calling the API" do
      expect(described_class).not_to receive(:call)

      ["foo", "#{vm.ubid}\nx", @account.ubid].each do |id|
        expect(mcp_tool_error("get_object_info", id:)).to eq "InvalidRequest: id must be a resource id such as vm..."
      end
    end
  end
end
