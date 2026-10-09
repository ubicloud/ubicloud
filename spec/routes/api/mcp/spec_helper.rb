# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  config.include(Module.new do
    def mcp(method, params = nil, id: 1, status: 200, env: {})
      body = {jsonrpc: "2.0", method:}
      body[:id] = id unless id.nil?
      body[:params] = params if params
      post("/mcp", body.to_json, env)
      expect(last_response.status).to eq(status), "status #{last_response.status}, body: #{last_response.body}"
      return nil if last_response.body.empty?
      JSON.parse(last_response.body)
    end

    def mcp_tool(name, **arguments)
      mcp("tools/call", {name:, arguments:}).fetch("result")
    end

    def mcp_tool_data(name, **arguments)
      result = mcp_tool(name, **arguments)
      expect(result["isError"]).to be(false), result.inspect
      result.fetch("structuredContent")
    end

    def mcp_tool_error(name, **arguments)
      result = mcp_tool(name, **arguments)
      expect(result["isError"]).to be(true), result.inspect
      result.dig("content", 0, "text")
    end

    def mcp_modern(method, params = {}, id: 1, status: 200, name: nil)
      params = params.merge(_meta: {"io.modelcontextprotocol/protocolVersion" => "2026-07-28", "io.modelcontextprotocol/clientCapabilities" => {}})
      env = {"HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28", "HTTP_MCP_METHOD" => method, "HTTP_ACCEPT" => "application/json, text/event-stream"}
      env["HTTP_MCP_NAME"] = name if name
      mcp(method, params, id:, status:, env:)
    end

    def restrict_pat_to(*action_names)
      @pat.restrict_token_for_project(@project.id)
      action_names.each { AccessControlEntry.create(project_id: @project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP[it]) }
    end
  end)

  config.define_derived_metadata(file_path: %r{\A\./spec/routes/api/mcp/}) do |metadata|
    metadata[:clover_mcp] = true
  end

  config.before do |example|
    next unless example.metadata[:clover_mcp]

    @account = create_account
    @use_pat = true
    @project = project_with_default_policy(@account, name: "project-1")
  end
end
