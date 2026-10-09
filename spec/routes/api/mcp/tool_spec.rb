# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UbiMcp::Tool do
  let(:pg_id) { "pg345678901234567890123456" }

  let(:adapter) do
    env = Rack::MockRequest.env_for("/mcp", "HTTP_HOST" => "api.ubicloud.com", "HTTP_AUTHORIZATION" => "Bearer pat-#{@pat.ubid}-#{@pat.key}", "CONTENT_TYPE" => "application/json")
    UbiMcp::ReadOnlyAdapter.new(app: Clover, env:, project_id: @project.ubid)
  end

  let(:server_context) { UbiMcp::Context.new }

  def call(tool, **arguments)
    tool.call(server_context:, **arguments).to_h
  end

  def raising_tool(body)
    Class.new(described_class) do
      define_singleton_method(:run) do |_adapter|
        raise Ubicloud::Error.new("unsuccessful response", code: 502, body:)
      end
    end
  end

  describe "shared schema properties" do
    it "advertises ref_property with the id prefix" do
      tool = Class.new(described_class) do
        input_schema(properties: {ref: ref_property("pg")})
      end

      expect(tool.input_schema.to_h[:properties]).to eq({ref: {type: "string", description: "location/name or a pg... id"}})
    end

    it "rejects arguments outside the shared location, limit and cursor properties" do
      schema = Class.new(described_class) do
        input_schema(properties: {location: UbiMcp::Tool::LOCATION_PROPERTY, limit: UbiMcp::Tool::LIMIT_PROPERTY, cursor: UbiMcp::Tool::CURSOR_PROPERTY})
      end.input_schema

      expect(schema.validate_arguments({location: "eu-central-h1", limit: 1000, cursor: "c"})).to be_nil
      [{limit: 0}, {limit: 1001}, {limit: "5"}, {location: 5}, {cursor: 5}].each do |arguments|
        expect { schema.validate_arguments(arguments) }.to raise_error(MCP::Tool::InputSchema::ValidationError)
      end
    end
  end

  describe ".call" do
    it "returns the data as text and as structured content" do
      tool = Class.new(described_class) do
        def self.run(_adapter)
          {name: "n", count: 2}
        end
      end

      expect(call(tool)).to eq({
        content: [{type: "text", text: '{"name":"n","count":2}'}],
        isError: false,
        structuredContent: {name: "n", count: 2},
      })
    end

    it "reports an API error with its details" do
      body = {error: {type: "T", message: "m", details: {k: "v"}}}.to_json
      expect(call(raising_tool(body))).to eq({content: [{type: "text", text: "T: m; k: v"}], isError: true})
      expect(server_context.tool_error).to eq "T"
    end

    it "reports an API error without details" do
      body = {error: {type: "T", message: "m", details: nil}}.to_json
      expect(call(raising_tool(body))).to eq({content: [{type: "text", text: "T: m"}], isError: true})
      expect(server_context.tool_error).to eq "T"
    end

    it "reports an Invalid reference as InvalidRequest" do
      tool = Class.new(described_class) do
        def self.run(adapter)
          resolve(adapter, "foo", prefix: "pg")
        end
      end

      expect(call(tool)).to eq({content: [{type: "text", text: "InvalidRequest: ref must be location/name or a pg... id"}], isError: true})
      expect(server_context.tool_error).to eq "InvalidRequest"
    end

    it "rejects a string argument or array item that is not valid UTF-8 before running" do
      tool = Class.new(described_class) do
        def self.run(_adapter, **)
          raise "not reached"
        end
      end

      expect(call(tool, ref: "loc/\xED\xB0\x80")).to eq({content: [{type: "text", text: "InvalidRequest: ref must be valid UTF-8"}], isError: true})
      expect(call(tool, limit: 5, keys: ["work_mem", "\xFF"])).to eq({content: [{type: "text", text: "InvalidRequest: keys must be valid UTF-8"}], isError: true})
    end

    it "runs with valid UTF-8 strings, arrays and other values" do
      tool = Class.new(described_class) do
        def self.run(_adapter, **arguments)
          arguments
        end
      end

      arguments = {ref: "loc/caf\u00e9", keys: ["work_mem"], limit: 5, points: true}
      expect(call(tool, **arguments)[:structuredContent]).to eq arguments
    end
  end

  describe ".resolve" do
    it "splits a location/name reference without an inner request" do
      expect(described_class.send(:resolve, nil, "loc/name", prefix: "pg")).to eq ["loc", "name"]
    end

    it "accepts API names on both sides" do
      expect(described_class.send(:resolve, nil, "eu-central-h1/orders-db", prefix: "pg")).to eq ["eu-central-h1", "orders-db"]
      expect(described_class.send(:resolve, nil, "#{"a" * 63}/#{"b" * 63}", prefix: "pg")).to eq ["a" * 63, "b" * 63]
    end

    it "rejects a location or name that breaks the API's name rule" do
      ["-eu/name", "eu-/name", "eu/-name", "eu/name-", "#{"a" * 64}/name", "eu/#{"b" * 64}", "/name", "eu/"].each do |ref|
        expect { described_class.send(:resolve, nil, ref, prefix: "pg") }.to raise_error(UbiMcp::Tool::Invalid, "ref must be location/name or a pg... id")
      end
    end

    it "rejects a malformed reference and an id of another type" do
      expect { described_class.send(:resolve, nil, "foo", prefix: "pg") }.to raise_error(UbiMcp::Tool::Invalid, "ref must be location/name or a pg... id")
      expect { described_class.send(:resolve, nil, "vm345678901234567890123456", prefix: "pg") }.to raise_error(UbiMcp::Tool::Invalid, "ref must be location/name or a pg... id")
    end

    it "rejects a reference that could leave its path segment" do
      ["loc/name?", "loc/na me", "loc/Name", "loc/../x", "loc/name\nx", "#{pg_id}\nx"].each do |ref|
        expect { described_class.send(:resolve, nil, ref, prefix: "pg") }.to raise_error(UbiMcp::Tool::Invalid, "ref must be location/name or a pg... id")
      end
    end

    it "resolves an id to its location through object-info and keeps the id" do
      vm = create_vm(project_id: @project.id)
      expect(described_class.send(:resolve, adapter, vm.ubid, prefix: "vm")).to eq ["eu-central-h1", vm.ubid]
    end

    it "fails when object-info returns a location that is not a display name" do
      location = Location.create(name: "bad", display_name: "bad/location", ui_name: "bad", visible: true, provider: "hetzner", project_id: @project.id)
      fw = Firewall.create(name: "fw-1", location_id: location.id, project_id: @project.id)
      expect { described_class.send(:resolve, adapter, fw.ubid, prefix: "fw") }.to raise_error(RuntimeError, "object-info returned location \"bad/location\" for #{fw.ubid}")
    end
  end

  describe ".object_info" do
    it "rejects anything but a resource id before calling the API" do
      ["foo", "#{pg_id}\nx", "#{pg_id}?x"].each do |id|
        expect { described_class.send(:object_info, nil, id) }.to raise_error(UbiMcp::Tool::Invalid, "id must be a resource id such as vm...")
      end
    end

    it "gets the object info of an id" do
      vm = create_vm(project_id: @project.id)
      expect(described_class.send(:object_info, adapter, vm.ubid)).to eq({type: "vm", location: "eu-central-h1", name: "test-vm"})
    end
  end

  describe ".location_path" do
    it "returns the fragment without a location" do
      expect(described_class.send(:location_path, nil, "vm")).to eq "vm"
    end

    it "scopes the fragment to a location" do
      expect(described_class.send(:location_path, "eu-central-h1", "vm")).to eq "location/eu-central-h1/vm"
    end

    it "rejects a location that is not an API name" do
      ["eu-central-h1/vm/x/serial-log?y", "eu-central-h1\nx", "EU Central", "-eu", "eu-", "a" * 64].each do |location|
        expect { described_class.send(:location_path, location, "vm") }.to raise_error(UbiMcp::Tool::Invalid, "location must be a display name such as eu-central-h1")
      end
    end
  end

  describe ".resource_path" do
    it "builds the location scoped path from the name or the id" do
      vm = create_vm(project_id: @project.id)
      expect(described_class.send(:resource_path, nil, "vm", "eu-central-h1/test-vm", prefix: "vm")).to eq "location/eu-central-h1/vm/test-vm"
      expect(described_class.send(:resource_path, adapter, "vm", vm.ubid, prefix: "vm")).to eq "location/eu-central-h1/vm/#{vm.ubid}"
    end
  end

  describe ".paged" do
    def paged(**)
      described_class.send(:paged, adapter, "vm", prefix: "vm", **)
    end

    it "rejects a cursor of another resource type before calling the API" do
      expect(Clover).not_to receive(:call)
      expect { paged(limit: 1, cursor: "fw345678901234567890123456") }.to raise_error(UbiMcp::Tool::Invalid, "cursor must be the next_cursor of a previous result")
    end

    it "pages in id order" do
      first, second = [create_vm(project_id: @project.id, name: "vm-b"), create_vm(project_id: @project.id, name: "vm-a")].sort_by(&:id)

      page = paged(limit: 1, cursor: nil)
      expect(page[:items].map { it[:id] }).to eq [first.ubid]
      expect(page[:count]).to eq 2
      expect(page[:next_cursor]).to eq first.ubid

      page = paged(limit: 2, cursor: page[:next_cursor])
      expect(page[:items].map { it[:id] }).to eq [second.ubid]
      expect(page[:count]).to eq 2
      expect(page[:next_cursor]).to be_nil
    end

    it "sends an integral float limit as an integer page size" do
      vm = create_vm(project_id: @project.id)
      page = paged(limit: 1.0, cursor: nil)
      expect(page[:items].map { it[:id] }).to eq [vm.ubid]
      expect(page[:next_cursor]).to eq vm.ubid
    end
  end
end
