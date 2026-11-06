# frozen_string_literal: true

require_relative "../openapi/norms"

RSpec.describe OpenapiNorms do
  def violations(paths, schemas: {}, responses: {}, parameters: {})
    doc = {"paths" => paths, "components" => {"schemas" => schemas, "responses" => responses, "parameters" => parameters}}
    described_class.new(doc).violations
  end

  # An operation that creates a Thing at its item path and returns it.
  def create(body, response = {"$ref" => "#/components/schemas/Thing"}, required: [], parameter: {"$ref" => "#/components/parameters/name"})
    {"/thing/{name}" => {"parameters" => [parameter], "post" => {
      "operationId" => "createThing",
      "requestBody" => {"content" => {"application/json" => {"schema" => {"type" => "object", "properties" => body, "required" => required}}}},
      "responses" => {"200" => {"content" => {"application/json" => {"schema" => response}}}},
    }}}
  end

  def thing(**props)
    id = {"type" => "string", "readOnly" => true, "description" => "ID", "example" => "th1"}
    {"Thing" => {"type" => "object", "properties" => {"id" => id, **props}}}
  end

  let(:name) { {"name" => {"name" => "name", "in" => "path", "description" => "Name", "schema" => {"type" => "string", "example" => "a"}}} }

  let(:size) { {"type" => "string", "description" => "Size", "example" => "s"} }

  it "accepts a create whose inputs the response echoes and whose other properties are readOnly" do
    expect(violations(create({"size" => size}), schemas: thing("size" => size), parameters: name)).to eq []
  end

  it "reports an input the response does not echo, and the property it should have been" do
    expect(violations(create({"enable_size" => size}), schemas: thing("size" => size), parameters: name)).to eq [
      "direction: Thing.size: mark it readOnly, or accept it in a request",
      "echo: createThing.enable_size: echo it in the response, or mark it writeOnly",
    ]
  end

  it "accepts an input that is writeOnly or deprecated, and finds properties through allOf, anyOf and responses" do
    response = {"anyOf" => [{"allOf" => [{"$ref" => "#/components/schemas/Thing"}, {"type" => "object", "properties" => {"size" => size}}]}]}
    old = size.merge("deprecated" => true, "x-deprecated" => {"since" => Date.new(2026, 11, 2), "removed-in" => 2})
    paths = create({"key" => size.merge("writeOnly" => true), "old" => old, "size" => size}, response)
    item = paths["/thing/{name}"]
    item["get"] = {"operationId" => "getThing", "responses" => {"200" => {"$ref" => "#/components/responses/Thing"}}}
    item["delete"] = {"operationId" => "deleteThing", "responses" => {"204" => {"description" => "Deleted"}}}
    item["put"] = {"operationId" => "replaceThing", "responses" => {"default" => {"description" => "An error"}}}
    readonly_size = {"type" => "object", "properties" => {"size" => size.merge("readOnly" => true)}}
    responses = {"Thing" => {"content" => {"application/json" => {"schema" => readonly_size}}}}
    expect(violations(paths, schemas: thing, responses:, parameters: name)).to eq []
  end

  it "reports a request that accepts less than the response it echoes into" do
    wider = {"anyOf" => [{"type" => "string"}, {"type" => "integer"}]}
    body = {"size" => size.merge("enum" => ["s"]), "count" => {"type" => "object", "description" => "Counts", "additionalProperties" => {"type" => "string"}}}
    props = {"size" => size.merge("enum" => %w[s m]), "count" => {"type" => "object", "description" => "Counts", "additionalProperties" => wider}}
    expect(violations(create(body), schemas: thing(**props), parameters: name)).to eq [
      "echo_agreement: createThing.size: accept every value Thing.size may hold",
      "echo_agreement: createThing.count: accept every value Thing.count may hold",
    ]
    body["count"]["additionalProperties"] = wider
    body["size"] = size.merge("anyOf" => [{"type" => "string", "enum" => %w[s m]}], "type" => nil)
    expect(violations(create(body), schemas: thing(**props), parameters: name)).to eq []
  end

  it "reports a place without a description or an example" do
    bare = {"type" => "string"}
    parameter = {"name" => "name", "in" => "path", "schema" => bare}
    expect(violations(create({"size" => bare}, required: ["size"], parameter:), schemas: thing("size" => bare))).to eq [
      "described: createThing.size: describe it",
      "described: Thing.size: describe it",
      "described: createThing param name: describe it",
      "examples: createThing param name: give it an example",
      "examples: createThing.size: give it an example",
    ]
    parameter["examples"] = {"name" => {"value" => "a"}}
    expect(violations(create({}, parameter:), schemas: thing)).to eq ["described: createThing param name: describe it"]
  end

  it "reports x-immutable on a property that is not readOnly" do
    body = {"size" => size.merge("x-immutable" => true)}
    schemas = thing("size" => size.merge("x-immutable" => true), "key" => size.merge("readOnly" => true, "x-immutable" => true))
    expect(violations(create(body), schemas:, parameters: name)).to eq [
      "immutable_readonly: createThing.size: mark it readOnly, or drop x-immutable",
      "immutable_readonly: Thing.size: mark it readOnly, or drop x-immutable",
    ]
  end

  it "reports x-lifecycle on a property that is not readOnly, with values outside its enum, or on more than one property" do
    state = {"type" => "string", "description" => "State", "readOnly" => true, "enum" => %w[creating ready failed]}
    marked = state.merge("x-lifecycle" => {"pending" => ["creating"], "failed" => ["failed"]})
    expect(violations(create({}), schemas: thing("state" => marked), parameters: name)).to eq []
    schemas = thing(
      "a" => marked.merge("readOnly" => false), "b" => state.merge("x-lifecycle" => {"pending" => ["starting"]}),
      "c" => state.merge("x-lifecycle" => ["creating"]), "d" => state.merge("x-lifecycle" => {"ready" => ["ready"]}),
      "e" => state.merge("x-lifecycle" => {"failed" => "failed"}),
    )
    expect(violations(create({}), schemas:, parameters: name).grep(/\Alifecycle/)).to eq [
      *%w[a b c d e].map { "lifecycle_enum: Thing.#{it}: mark it readOnly, and list only values of its enum under pending and failed" },
      "lifecycle_enum: Thing.a, Thing.b, Thing.c, Thing.d, Thing.e: mark only one property of a response with x-lifecycle",
    ]
  end

  describe "deprecation" do
    def deprecated(**x) = size.merge("deprecated" => true, "x-deprecated" => {"since" => Date.new(2026, 11, 2), **x})

    it "accepts a deprecated input that names its removal and a sibling or operation to use, and a deprecated response property" do
      body = {"old" => deprecated("removed-in" => 2, "use" => ["size"]), "older" => deprecated("removed-in" => 3, "use" => ["getThing"]),
              "renamed" => deprecated("removed-in" => 2, "renamed-to" => "size"), "size" => size}
      paths = create(body)
      paths["/thing/{name}"]["post"].merge!("deprecated" => true, "x-deprecated" => {"since" => Date.new(2025, 1, 1), "removed-in" => 2, "use" => ["getThing"]})
      paths["/thing/{name}"]["get"] = {"operationId" => "getThing", "responses" => {"200" => paths["/thing/{name}"]["post"]["responses"]["200"]}}
      schemas = thing("size" => size, "old" => deprecated("use" => ["size"]), "older" => deprecated)
      expect(violations(paths, schemas:, parameters: name)).to eq []
    end

    it "reports a deprecation that does not say what the API does with it" do
      body = {"a" => size.merge("deprecated" => true), "b" => deprecated("since" => "soon", "removed-in" => 1, "use" => "size"),
              "c" => deprecated("removed-in" => 2, "use" => ["gone"]), "e" => deprecated("removed-in" => 2, "renamed-to" => "c"),
              "f" => deprecated("removed-in" => 2, "renamed-to" => "count"), "count" => {"type" => "integer"}}
      schemas = thing("d" => deprecated("removed-in" => 2, "renamed-to" => "id"))
      expect(violations(create(body, required: ["c"]), schemas:, parameters: name).grep(/\Adeprecation/)).to eq [
        "deprecation: createThing.a: give it both deprecated: true and x-deprecated",
        "deprecation: createThing.b: give x-deprecated a since date; make use a list of names that exist; give x-deprecated removed-in, an API version above 1",
        "deprecation: createThing.c: make use a list of names that exist; take it out of required, since a client may send its replacement instead",
        "deprecation: createThing.e: make renamed-to name a sibling request property of the same type",
        "deprecation: createThing.f: make renamed-to name a sibling request property of the same type",
        "deprecation: Thing.d: drop removed-in, since responses are the same in every version; make renamed-to name a sibling request property of the same type",
      ]
    end
  end

  it "checks only the operations it is given, whose deprecations may name any operation" do
    other = {"get" => {"operationId" => "getOther", "responses" => {"200" => {"content" => {"application/json" => {"schema" => {"type" => "object", "properties" => {"size" => size}}}}}}}}
    old = size.merge("deprecated" => true, "x-deprecated" => {"since" => Date.new(2026, 11, 2), "removed-in" => 2, "use" => ["getOther"]})
    doc = {"paths" => create({"size" => size, "old" => old}).merge("/other" => other), "components" => {"schemas" => thing("size" => size), "parameters" => name}}
    expect(described_class.new(doc).violations).to eq ["direction: getOther 200.size: mark it readOnly, or accept it in a request"]
    expect(described_class.new(doc, only: %w[createThing]).violations).to eq []
  end

  it "holds for openapi.yml, but for the known violations, which may only shrink" do
    found = described_class.new(YAML.safe_load_file("openapi/openapi.yml", permitted_classes: [Date, Time])).violations.sort
    known = File.readlines("openapi/norms-known.txt", chomp: true)
    expect(found - known).to eq([]), "openapi.yml breaks these norms; keep to them:\n#{(found - known).join("\n")}"
    expect(known - found).to eq([]), "openapi.yml now keeps these norms; delete these lines from openapi/norms-known.txt:\n#{(known - found).join("\n")}"
  end
end
