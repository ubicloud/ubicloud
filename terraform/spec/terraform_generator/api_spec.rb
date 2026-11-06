# frozen_string_literal: true

RSpec.describe TerraformGenerator::Api do
  def api(paths, **components)
    described_class.new(openapi(paths: {"/project/{project_id}": {get: {}}, **paths}, **components))
  end

  def post(op, **components) = api({"/project/{project_id}/thing": {post: op}}, **components).paths["/project/{project_id}/thing"]["post"]

  def body(schema) = {content: {"application/json": {schema:}}}

  def body_schema(op) = op.dig("requestBody", "content", "application/json", "schema")

  def item_names(*paths) = api(paths.to_h { [it, {get: {}}] }).items.keys

  it "loads openapi/openapi.yml by its absolute path, from any directory" do
    loaded = Dir.chdir("/") { described_class.load }
    expect(loaded.scope).to eq "/project/{project_id}"
    expect(loaded.items).to include("firewall_rule")
  end

  it "is frozen throughout" do
    loaded = api({"/project/{project_id}/thing/{thing_id}": {get: {parameters: [{name: "thing_id", in: "path"}]}}})
    expect(Ractor.shareable?(loaded)).to be true
  end

  describe "$ref" do
    it "resolves a parameter, keeping the $ref beside what it names" do
      op = post({parameters: [{"$ref": "#/components/parameters/dry_run"}]}, parameters: {dry_run: {name: "dry_run", in: "query"}})
      expect(op["parameters"]).to eq [{"$ref" => "#/components/parameters/dry_run", "name" => "dry_run", "in" => "query"}]
    end

    it "resolves a request body" do
      op = post({requestBody: {"$ref": "#/components/requestBodies/NewThing"}}, requestBodies: {NewThing: body(type: "object")})
      expect(op["requestBody"]).to eq("$ref" => "#/components/requestBodies/NewThing", "content" => {"application/json" => {"schema" => {"type" => "object"}}})
    end

    it "resolves a response" do
      op = post({responses: {"200": {"$ref": "#/components/responses/Thing"}}}, responses: {Thing: {description: "A thing"}})
      expect(op["responses"]).to eq("200" => {"$ref" => "#/components/responses/Thing", "description" => "A thing"})
    end

    it "resolves a schema and the schemas it refers to, keeping the first $ref of a chain" do
      schemas = {Thing: {type: "array", items: {"$ref": "#/components/schemas/Part"}}, Part: {"$ref": "#/components/schemas/Name"}, Name: {type: "string"}}
      schema = body_schema(post({requestBody: body("$ref": "#/components/schemas/Thing")}, schemas:))
      expect(schema).to eq("$ref" => "#/components/schemas/Thing", "type" => "array", "items" => {"$ref" => "#/components/schemas/Part", "type" => "string"})
    end
  end

  describe "allOf" do
    it "merges the properties and required lists of the members, then of the schema, a later one winning, and keeps the members" do
      base = {type: "object", properties: {id: {type: "string"}, size: {type: "string"}}, required: ["id"]}
      more = {type: "object", properties: {size: {type: "integer"}, name: {type: "string"}}, required: ["id", "size"]}
      own = {type: "object", additionalProperties: false, properties: {name: {type: "string", maxLength: 63}}, required: ["name"]}
      schema = body_schema(post({requestBody: body(**own, allOf: [{"$ref": "#/components/schemas/Base"}, more])}, schemas: {Base: base}))
      expect(schema.except("allOf")).to eq(
        "type" => "object",
        "additionalProperties" => false,
        "properties" => {"id" => {"type" => "string"}, "size" => {"type" => "integer"}, "name" => {"type" => "string", "maxLength" => 63}},
        "required" => %w[id size name],
      )
      expect(schema["allOf"].map { it["$ref"] }).to eq ["#/components/schemas/Base", nil]
    end
  end

  describe "#paths" do
    it "gives each operation the parameters of its path, unless it declares one of the same name and location" do
      shared = [{name: "thing_id", in: "path"}, {name: "thing_id", in: "query"}]
      paths = {"/project/{project_id}/thing/{thing_id}": {parameters: shared, get: {}, post: {parameters: [{name: "thing_id", in: "path", description: "New"}]}}}
      ops = api(paths).paths["/project/{project_id}/thing/{thing_id}"]
      expect(ops.transform_values { |op| op["parameters"].map { it.values_at("in", "description") } })
        .to eq("get" => [["path", nil], ["query", nil]], "post" => [["path", "New"], ["query", nil]])
    end
  end

  describe "#items" do
    it "indexes the paths that end in a parameter and have a GET or a DELETE" do
      paths = {
        "/project/{project_id}/thing": {get: {}, post: {}},
        "/project/{project_id}/thing/{thing_id}": {delete: {}},
        "/project/{project_id}/thing/{thing_id}/start": {post: {}},
        "/project/{project_id}/thing/{thing_id}/part/{part_id}": {post: {}},
      }
      expect(api(paths).items.transform_values(&:path)).to eq("project" => "/project/{project_id}", "thing" => "/project/{project_id}/thing/{thing_id}")
    end

    it "gives an item its path parameters in path order, wherever they are declared" do
      declared = [{name: "thing_id", in: "path"}, {name: "dry_run", in: "query"}, {name: "location", in: "path"}]
      paths = {"/project/{project_id}/location/{location}/thing/{thing_id}": {parameters: declared, delete: {parameters: [{name: "project_id", in: "path"}]}}}
      expect(api(paths).items["thing"].params.map { it["name"] }).to eq %w[project_id location thing_id]
    end

    it "takes the shortest item path as the scope" do
      found = described_class.new(openapi(paths: {"/org/{org_id}/team/{team_id}": {get: {}}, "/org/{org_id}": {get: {}}}))
      expect(found.scope).to eq "/org/{org_id}"
      expect(found.items.keys).to eq %w[team org]
    end

    it "refuses an item path that does not begin with the scope" do
      expect { api({"/other/{other_id}/thing/{thing_id}": {get: {}}}) }
        .to raise_error(TerraformGenerator::SpecError, "item path /other/{other_id}/thing/{thing_id} does not begin with /project/{project_id}, the shortest item path")
    end
  end

  describe "type_name" do
    it "joins the nouns before parameters, after the scope and a location, and names the scope after its noun" do
      expect(item_names(
        "/project/{project_id}/location/{location}/load-balancer/{load_balancer_reference}",
        "/project/{project_id}/github/{installation}/repository/{repository}/cache/entry/{entry_id}",
      )).to eq %w[project load_balancer github_repository_entry]
    end

    it "drops a parent noun that the child noun begins with, followed by a hyphen" do
      expect(item_names(
        "/project/{project_id}/location/{location}/firewall/{firewall_reference}/firewall-rule/{firewall_rule_id}",
        "/project/{project_id}/location/{location}/postgres/{postgres_database_reference}/firewall-rule/{firewall_rule_id}",
        "/project/{project_id}/location/{location}/kubernetes-cluster/{kubernetes_cluster_reference}/nodepool/{kubernetes_nodepool_reference}",
        "/project/{project_id}/thing/{thing_id}/thingamajig/{thingamajig_id}",
      )).to eq %w[project firewall_rule postgres_firewall_rule kubernetes_cluster_nodepool thing_thingamajig]
    end

    it "refuses two item paths that derive the same name" do
      expect { item_names("/project/{project_id}/thing/{thing_id}", "/project/{project_id}/location/{location}/thing/{thing_id}") }
        .to raise_error(TerraformGenerator::SpecError, "/project/{project_id}/thing/{thing_id} and /project/{project_id}/location/{location}/thing/{thing_id} derive the same type name, thing")
    end
  end
end
