# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"

  SimpleCov.start do
    coverage :line, minimum: 100 do
      minimum 100, per: :file
    end
    coverage :branch, minimum: 100 do
      minimum 100, per: :file
    end

    root File.expand_path("../..", __dir__)
    coverage_dir "coverage/terraform"
    cover "terraform/lib/**/*.rb"

    group("Missing") { |src| src.covered_percent < 100 }
    group("Covered") { |src| src.covered_percent == 100 }
  end
end

require_relative "../lib/terraform_generator"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random

  config.include(Module.new do
    # Specs write the document with symbol keys, and this gives it the
    # string keys that YAML would. A round trip through JSON would do the
    # same, but would turn a Date into a String, which norm_deprecation
    # refuses as an x-deprecated since date.
    def openapi(paths:, **components) = string_keys({paths:, components:})

    def string_keys(node)
      case node
      in Hash then node.to_h { |k, v| [k.to_s, string_keys(v)] }
      in Array then node.map { string_keys(it) }
      else node
      end
    end

    # A spec with the scope and one type, thing, whose item GET returns a
    # readOnly id. An example adds what it needs: a create body, response
    # properties, operations on the item, and paths under the scope.
    def thing(create: nil, required: [], example: nil, on_item: false, response: {}, item: "/thing/{thing_id}", ops: {}, paths: {}, schemas: {}, responses: {})
      item = "/project/{project_id}#{item}"
      all = {
        "/project/{project_id}" => path_item("/project/{project_id}", get: op("getScope", response: "Scope")),
        item => path_item(item, get: op("getThing"), delete: {operationId: "deleteThing", responses: {"204": {description: "Deleted"}}}, **ops),
        **paths.transform_keys { "/project/{project_id}#{it}" },
      }
      (all[on_item ? item : item.sub(%r{/\{\w+\}\z}, "")] ||= {})[:post] = op("createThing", create, required:, example:) if create
      openapi(
        paths: all,
        schemas: {Reference: {description: "ID or name", type: "string", pattern: "^[a-z0-9-]+$"}, **schemas},
        responses: {
          Scope: {description: "The scope", **json(object({id: {type: "string", readOnly: true}}))},
          Thing: {description: "A thing", **json(object({id: {type: "string", readOnly: true}, **response}))},
          **responses,
        },
      )
    end

    def derive(facts = {}, name: :thing, **parts) = TerraformGenerator.types(TerraformGenerator::Api.new(thing(**parts)), {name => facts}).first

    def derive_attr(name, **parts) = derive(**parts).statements.find { it.is_a?(TerraformGenerator::Attr) && it.name == name.to_s }

    def call(name, *args) = TerraformGenerator::Call.new(name, args)

    # Properties get a description and an example unless they state their own.
    def object(props = {}, **schema) = {type: "object", properties: props.transform_values { {description: "Its description", example: "x", **it} }, **schema}

    def json(schema) = {content: {"application/json": {schema:}}}

    def op(id, body = nil, required: [], example: nil, response: "Thing")
      {operationId: id, **(body ? {requestBody: json(object(body, required:, **{example:}.compact))} : {}), responses: {"200": {"$ref": "#/components/responses/#{response}"}}}
    end

    # A path item with a parameter for each placeholder in its path. A
    # parameter whose placeholder ends in _reference accepts a name.
    def path_item(path, **ops)
      params = path.scan(/\{(\w+)\}/).flatten.map do |name|
        schema = name.end_with?("_reference") ? {"$ref": "#/components/schemas/Reference"} : {type: "string"}
        {name:, in: "path", required: true, description: "The #{name}", example: "x", schema:}
      end
      {parameters: params, **ops}
    end
  end)
end
