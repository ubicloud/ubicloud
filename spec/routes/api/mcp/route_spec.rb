# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp route" do
  let(:initialize_params) { {protocolVersion: "2025-11-25", capabilities: {}, clientInfo: {name: "spec", version: "1"}} }
  let(:modern_env) { {"HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28", "HTTP_MCP_METHOD" => "tools/list", "HTTP_ACCEPT" => "application/json, text/event-stream"} }
  let(:parse_error) { {"jsonrpc" => "2.0", "id" => nil, "error" => {"code" => -32700, "message" => "Parse error: Invalid JSON"}} }

  it "returns 401 without an Authorization header" do
    header "Authorization", nil
    mcp("initialize", initialize_params, status: 401)
    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end

  it "returns 401 for a garbled Authorization header" do
    header "Authorization", "Bearer wrongjwt"
    mcp("initialize", initialize_params, status: 401)
    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end

  it "returns 401 for an invalid personal access token" do
    header "Authorization", "Bearer pat-"
    mcp("initialize", initialize_params, status: 401)
    expect(last_response).to have_api_error(401, "invalid personal access token provided in Authorization header")
  end

  it "returns 401 for GET without an Authorization header" do
    header "Authorization", nil
    get "/mcp"
    expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
  end

  it "answers methods other than POST with 405 and Allow: POST in every protocol era" do
    [
      ["GET", {}], ["PUT", {}], ["DELETE", {}], ["DELETE", {"HTTP_MCP_PROTOCOL_VERSION" => "2025-11-25"}],
      ["DELETE", modern_env.merge("HTTP_MCP_SESSION_ID" => "x")], ["DELETE", modern_env],
    ].each do |method, env|
      custom_request(method, "/mcp", nil, env)
      expect(last_response.status).to eq 405
      expect(last_response.headers["allow"]).to eq "POST"
      expect(JSON.parse(last_response.body)).to eq({"jsonrpc" => "2.0", "id" => nil, "error" => {"code" => -32600, "message" => "Method not allowed"}})
    end
  end

  it "answers raw bytes or an escaped object key that are not valid UTF-8 with a parse error in every protocol era" do
    expect(Clog).not_to receive(:emit)
    bodies = [
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"x\":\"\xFF\"}",
      '{"jsonrpc":"2.0","id":1,"method":"tools/list","\udc00":1}',
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_object_info","arguments":{"\udc00":1}}}',
    ]
    bodies.product([{}, modern_env, modern_env.merge("HTTP_MCP_PROTOCOL_VERSION" => "9999-01-01")]).each do |body, env|
      post("/mcp", body, env)
      expect(last_response.status).to eq 400
      expect(JSON.parse(last_response.body)).to eq parse_error
    end
  end

  it "leaves a body nested deeper than the transport parses to the transport, even with an invalid key past that depth" do
    post("/mcp", "#{"[" * 65}{\"\\udc00\":1}#{"]" * 65}", "HTTP_ACCEPT" => "text/plain")
    expect(last_response.status).to eq 406
  end

  it "answers an empty body with a parse error" do
    post("/mcp", "")
    expect(last_response.status).to eq 400
    expect(JSON.parse(last_response.body)).to eq parse_error
  end

  it "leaves a body over the size limit to the transport even when the limit splits a character" do
    post("/mcp", "{\"a\":\"#{"\u00e9" * 40_000}\"}")
    expect(last_response.status).to eq 413
  end

  it "reads at most one byte past the size limit of a body declared over it" do
    input = Class.new(StringIO) do
      def lengths
        @lengths ||= []
      end

      def read(length = nil, *)
        lengths << length
        super
      end
    end.new("{\"a\":\"#{"x" * UbiMcp::MAX_REQUEST_BYTES}\"}")

    status, = UbiMcp.process({
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => input.size.to_s,
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "rack.input" => input,
      "clover.project_ubid" => @project.ubid,
    })
    expect(status).to eq 413
    expect(input.lengths).to eq [UbiMcp::MAX_REQUEST_BYTES + 1]
  end

  it "answers a tool argument that is not valid UTF-8 with InvalidRequest" do
    post("/mcp", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_object_info","arguments":{"id":"vm\udc00"}}}')
    expect(last_response.status).to eq 200
    expect(JSON.parse(last_response.body).fetch("result")).to eq({"content" => [{"type" => "text", "text" => "InvalidRequest: id must be valid UTF-8"}], "isError" => true})
  end

  it "serves the legacy lifecycle" do
    result = mcp("initialize", initialize_params).fetch("result")
    expect(result["protocolVersion"]).to eq "2025-11-25"
    expect(result["capabilities"]).to eq({"tools" => {}})
    expect(result.dig("serverInfo", "name")).to eq "ubicloud"
    expect(result["instructions"]).to include @project.ubid

    expect(mcp("notifications/initialized", id: nil, status: 202)).to be_nil

    result = mcp("tools/list").fetch("result")
    expect(result["tools"].map { it["name"] }).to eq UbiMcp::TOOLS.map(&:tool_name)
    expect(result["ttlMs"]).to eq 3600000
    expect(result["cacheScope"]).to eq "private"

    response = mcp("tools/call", {name: "nope", arguments: {}})
    expect(response).not_to have_key("result")
    expect(response.dig("error", "code")).to eq(-32602)
    expect(response.dig("error", "data")).to eq "Tool not found: nope"

    result = mcp("tools/call", {name: "get_object_info", arguments: {}}).fetch("result")
    expect(result["isError"]).to be true
    expect(result.dig("content", 0, "text")).to eq "Missing required arguments: id"
  end

  it "echoes the protocol version Codex negotiates" do
    result = mcp("initialize", initialize_params.merge(protocolVersion: "2025-06-18")).fetch("result")
    expect(result["protocolVersion"]).to eq "2025-06-18"
  end

  it "serves the modern lifecycle" do
    vm = create_vm(project_id: @project.id)

    result = mcp_modern("server/discover").fetch("result")
    expect(result["supportedVersions"]).to eq ["2026-07-28"]
    expect(result["resultType"]).to eq "complete"
    expect(result["instructions"]).to include @project.ubid

    result = mcp_modern("tools/call", {name: "get_object_info", arguments: {id: vm.ubid}}, name: "get_object_info").fetch("result")
    expect(result["structuredContent"]).to eq({"type" => "vm", "location" => "eu-central-h1", "name" => "test-vm"})

    error = mcp_modern("tools/call", {name: "get_object_info", arguments: {id: vm.ubid}}, status: 400).fetch("error")
    expect(error["code"]).to eq(-32020)
  end

  describe "request log" do
    def expect_request_log(error:, method: "tools/call", tool: "get_object_info")
      expect(Clog).to receive(:emit).with("mcp request", {mcp_request: {method:, tool:, project: @project.ubid, error:, duration: Float}}).and_call_original
    end

    it "logs a successful tool call" do
      vm = create_vm(project_id: @project.id)
      expect_request_log(error: nil)
      mcp_tool_data("get_object_info", id: vm.ubid)
    end

    it "logs a failed tool call with its error type in both protocol eras" do
      expect_request_log(error: "ResourceNotFound")
      expect_request_log(error: "InvalidRequest")

      expect(mcp_tool_error("get_object_info", id: "vm345678901234567890123456")).to start_with "ResourceNotFound: "
      result = mcp_modern("tools/call", {name: "get_object_info", arguments: {id: "foo"}}, name: "get_object_info").fetch("result")
      expect(result.dig("content", 0, "text")).to eq "InvalidRequest: id must be a resource id such as vm..."
    end

    it "logs no tool name for an unknown tool and reports no exception for client errors" do
      expect_request_log(error: :invalid_params, tool: nil)
      expect_request_log(error: :invalid_params, method: "initialize", tool: nil)
      expect(Clog).not_to receive(:emit).with("mcp exception", anything)

      expect(mcp("tools/call", {name: "get_object_info_#{"x" * 100}", arguments: {}}).dig("error", "code")).to eq(-32602)
      expect(mcp("initialize", {}).dig("error", "data")).to eq "Missing or invalid protocolVersion"
    end

    it "turns tool exceptions into internal errors and reports them with 50 frames of backtrace" do
      requests = []
      expect(described_class).to receive(:call) do |env|
        requests << [env["REQUEST_METHOD"], env["PATH_INFO"], env["HTTP_ACCEPT"]]
        raise "boom"
      end
      expect(Clog).to receive(:emit).with("mcp exception", {exception: {message: "boom", class: "RuntimeError", backtrace: an_instance_of(Array).and(have_attributes(size: 50))}}).and_call_original
      expect_request_log(error: :internal_error)

      error = mcp("tools/call", {name: "get_object_info", arguments: {id: "vm345678901234567890123456"}}).fetch("error")
      expect(error).to eq({"code" => -32603, "message" => "Internal error", "data" => "Internal error calling tool get_object_info"})
      expect(requests).to eq [["GET", "/project/#{@project.ubid}/object-info/vm345678901234567890123456", "application/json"]]
    end

    it "reports errors the gem raises on malformed input without a backtrace" do
      expect(Clog).to receive(:emit).with("mcp exception", {exception: {message: "undefined method 'keys' for an instance of Array", class: "NoMethodError", backtrace: nil}}).and_call_original
      expect_request_log(error: :internal_error)
      expect(Clog).to receive(:emit).with("mcp exception", {exception: {message: "undefined method 'strip' for nil", class: "NoMethodError", backtrace: nil}}).and_call_original

      error = mcp("tools/call", {name: "get_object_info", arguments: []}).fetch("error")
      expect(error).to eq({"code" => -32603, "message" => "Internal error", "data" => "Internal error calling tool get_object_info"})
      error = mcp("tools/list", env: {"HTTP_ACCEPT" => "a,,b"}, status: 500).fetch("error")
      expect(error).to eq({"code" => -32603, "message" => "Internal server error"})
    end
  end
end
