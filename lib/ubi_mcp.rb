# frozen_string_literal: true

require "mcp"
require_relative "../sdk/ruby/lib/ubicloud"
require_relative "../sdk/ruby/lib/ubicloud/adapter/rack"

module UbiMcp
  VERSION = "0.1.0"

  class DirectModelAccess < StandardError; end

  Context = Struct.new(:adapter, :project_ubid, :tool_error)

  class ReadOnlyAdapter < Ubicloud::Adapter::Rack
    def initialize(app:, env:, project_id:)
      super(app:, env: env.merge("HTTP_ACCEPT" => "application/json"), project_id:)
    end

    private

    def call(method, ...)
      raise ArgumentError, "read-only adapter cannot send #{method} requests" unless method == "GET"
      super
    end
  end

  class Tool < MCP::Tool
    READ_ONLY = {read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false}.freeze
    LOCATION_PROPERTY = {type: "string", description: "Only resources in this location"}.freeze
    LIMIT_PROPERTY = {type: "integer", minimum: 1, maximum: 1000, description: "Page size (default 50)"}.freeze
    CURSOR_PROPERTY = {type: "string", description: "next_cursor of the previous page"}.freeze

    class Invalid < Ubicloud::Error
      def params
        {"error" => {"type" => "InvalidRequest", "message" => message}}
      end
    end

    class << self
      def inherited(subclass)
        super
        subclass.annotations(READ_ONLY)
      end

      def ref_property(prefix)
        {type: "string", description: "location/name or a #{prefix}... id"}
      end

      def call(server_context:, **args)
        invalid, = args.find { |_, value| !valid_utf8?(value) }
        raise Invalid, "#{invalid} must be valid UTF-8" if invalid

        data = run(server_context.adapter, **args)
        MCP::Tool::Response.new([{type: "text", text: JSON.generate(data)}], structured_content: data)
      rescue Ubicloud::Error => e
        error_response(server_context, e)
      end

      private

      def valid_utf8?(value)
        case value
        when String then value.valid_encoding?
        when Array then value.all? { valid_utf8?(it) }
        else true
        end
      end

      def error_response(server_context, e)
        error = e.params["error"]
        details = error["details"]
        detail_text = details.is_a?(Hash) ? details.map { |k, v| "; #{k}: #{v}" }.join : ""
        server_context.tool_error = type = error["type"]
        MCP::Tool::Response.new([{type: "text", text: "#{type}: #{error["message"]}#{detail_text}"}], error: true)
      end

      def object_info(adapter, id)
        raise Invalid, "id must be a resource id such as vm..." unless UbiCli::EXACT_OBJECT_INFO_REGEXP.match?(id)
        adapter.get("object-info/#{id}")
      end

      def resolve(adapter, ref, prefix:)
        location, name = ref.split("/", 2)
        if name && Validation::ALLOWED_NAME_PATTERN.match?(location) && Validation::ALLOWED_NAME_PATTERN.match?(name)
          [location, name]
        elsif UbiCli::EXACT_OBJECT_INFO_REGEXP.match?(ref) && ref.start_with?(prefix)
          location = object_info(adapter, ref)[:location]
          fail "object-info returned location #{location.inspect} for #{ref}" unless Validation::ALLOWED_NAME_PATTERN.match?(location)
          [location, ref]
        else
          raise Invalid, "ref must be location/name or a #{prefix}... id"
        end
      end

      def resource_path(adapter, kind, ref, prefix:)
        location, name_or_id = resolve(adapter, ref, prefix:)
        "location/#{location}/#{kind}/#{name_or_id}"
      end

      def location_path(location, fragment)
        return fragment unless location
        raise Invalid, "location must be a display name such as eu-central-h1" unless Validation::ALLOWED_NAME_PATTERN.match?(location)
        "location/#{location}/#{fragment}"
      end

      def paged(adapter, path, prefix:, limit:, cursor:, **extra)
        raise Invalid, "cursor must be the next_cursor of a previous result" if cursor && !cursor.start_with?(prefix)
        page = adapter.get(path, {page_size: limit.to_i, start_after: cursor, **extra})
        items = page[:items]
        next_cursor = items.last[:id] if items.size >= limit
        {items:, count: page[:count], next_cursor:}
      end
    end
  end

  module Tools
  end

  INSTRUCTIONS_TEMPLATE = <<~TEXT
    Read-only access to Ubicloud project <PROJECT_UBID> (the project this token
    belongs to). Locations are given by display name, and a `ref` is
    `location/name` (for example `eu-central-h1/db1`) or the resource's id.
    Tools that take a `cursor` return `next_cursor`; pass it as `cursor`, with
    the same other arguments, for the next page. A `count` is the total, not the
    page size. Resource lists silently leave out what the token cannot view.
    Poll `get_postgres` instead of assuming a database operation finished.
    Results leave out database passwords, connection strings and destination
    credentials, but return configuration overrides and log lines as stored,
    which can contain secrets, query text and data values. Error types include
    ResourceNotFound (no such resource, or an id the token cannot view),
    Forbidden (the token lacks a permission), InvalidRequest, BadRequest and
    InvalidLocation (a bad argument), and NotFound (metrics or log aggregation
    is not set up for this Ubicloud installation).
  TEXT

  MAX_REQUEST_BYTES = 64 * 1024
  PARSE_ERROR = {jsonrpc: "2.0", id: nil, error: {code: JsonRpcHandler::ErrorCode::PARSE_ERROR, message: "Parse error: Invalid JSON"}}.to_json.freeze
  METHOD_NOT_ALLOWED = {jsonrpc: "2.0", id: nil, error: {code: JsonRpcHandler::ErrorCode::INVALID_REQUEST, message: "Method not allowed"}}.to_json.freeze

  def self.process(env)
    unless env["REQUEST_METHOD"] == "POST"
      return [405, {"content-type" => "application/json", "allow" => "POST"}, [METHOD_NOT_ALLOWED]]
    end

    if encoding_error?(env["rack.input"])
      return [400, {"content-type" => "application/json"}, [PARSE_ERROR]]
    end

    project_ubid = env["clover.project_ubid"]
    adapter = ReadOnlyAdapter.new(app: Clover, env:, project_id: project_ubid)
    server = MCP::Server.new(
      name: "ubicloud",
      version: VERSION,
      instructions: INSTRUCTIONS_TEMPLATE.sub("<PROJECT_UBID>", project_ubid),
      tools: TOOLS,
      capabilities: {tools: {}},
      ttl_ms: 3_600_000,
      cache_scope: "private",
      server_context: Context.new(adapter:, project_ubid:),
    )
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      serve_subscriptions_listen: false,
      dns_rebinding_protection: false,
      max_request_bytes: MAX_REQUEST_BYTES,
    )
    transport.call(env)
  end

  private_class_method def self.encoding_error?(input)
    body = input.read(MAX_REQUEST_BYTES + 1)
    input.rewind
    return false unless body && body.bytesize <= MAX_REQUEST_BYTES
    return true unless body.force_encoding(Encoding::UTF_8).valid_encoding?
    JSON.parse(body, symbolize_names: true, max_nesting: MCP::Server::Transports::StreamableHTTPTransport::MAX_JSON_NESTING)
    false
  rescue JSON::ParserError
    false
  rescue EncodingError
    true
  end

  MCP.configure do |config|
    config.instrument_server_context = true
    config.exception_reporter = lambda do |exception, _context|
      next if exception.is_a?(MCP::Server::RequestHandlerError)
      hash = if exception.backtrace.any? { it.end_with?("in 'UbiMcp::Tool.call'") }
        Util.exception_to_hash(exception)
      else
        Util.exception_to_hash(exception, backtrace: nil)
      end
      Clog.emit("mcp exception", hash)
    end
    config.around_request = lambda do |data, &handler|
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      handler.call
    ensure
      tool = data[:tool_name]
      context = data[:server_context]
      Clog.emit("mcp request", mcp_request: {
        method: data[:method],
        tool: (tool if TOOLS.any? { it.tool_name == tool }),
        project: context.project_ubid,
        error: data[:error] || context.tool_error,
        duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - start,
      })
    end
  end

  # simplecov:disable
  if Config.frozen_test?
    singleton_class.prepend(Module.new do
      def process(env)
        DB.block_queries do
          super
        end
      end
    end)
  end
  # simplecov:enable

  if Config.unfrozen_test? && ENV["FORCE_AUTOLOAD"] == "1"
    def self.models_loaded
      Sequel::Model.descendants.each do |model|
        name = model.name
        autoload(name, "./vendor/hidden_mcp_class") if /\A[A-Za-z0-9]+\z/.match?(name)
      end
      autoload(:DB, "./vendor/hidden_mcp_class")
    end
  # simplecov:disable
  else
    def self.models_loaded
      # nothing
    end
  end
  # simplecov:enable

  Unreloader.record_dependency(__FILE__, "mcp-tools")
  Unreloader.require("mcp-tools") {}

  TOOLS = Tools.constants.map { Tools.const_get(it) }.sort_by(&:tool_name).freeze
end
