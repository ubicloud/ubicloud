# frozen_string_literal: true

RSpec.describe TerraformGenerator::Derive do
  def statements(type, kind) = type.statements.grep(TerraformGenerator.const_get(kind))

  def expect_refusal(message, facts = {}, **parts) = expect { derive(facts, **parts) }.to raise_error(TerraformGenerator::SpecError, message)

  def parent
    id = {type: "string", readOnly: true, pattern: "^pa[0-9a-z]{24}$", description: "ID of the parent"}
    {"/parent/{parent_reference}" => path_item("/project/{project_id}/parent/{parent_reference}", get: {operationId: "getParent", responses: {"200": {description: "A parent", **json(object({id:}))}}})}
  end

  def verb(id, body) = op(id, body)

  # An item path's parameters, with examples in place of the identity's example.
  def identity_examples(item, **examples) = path_item("/project/{project_id}#{item}")[:parameters].then { [*it[...-1], it.last.except(:example).merge(examples:)] }

  describe "type_name" do
    it "names the type, writes its item path in attribute names, and takes its description from the item response" do
      type = derive(create: {})
      expect(type.to_h.except(:statements, :examples, :example_inputs, :references)).to eq(
        name: "thing",
        item: "/project/{project_id}/thing/{id}",
        doc: "A thing",
        why: [[:type_name, "getThing"], [:doc, "Thing"]],
      )
    end
  end

  describe "kinds" do
    it "gives a named type a datasource looked up by id or name, and a resource when it has a create" do
      expect(statements(derive(item: "/thing/{thing_reference}"), :Datasource))
        .to eq [TerraformGenerator::Datasource.new(%w[id name], [[:kinds, "{thing_reference}"]])]
      expect(derive(create: {}, item: "/thing/{thing_reference}").statements.map(&:class)).to eq [TerraformGenerator::Create, TerraformGenerator::Datasource, TerraformGenerator::Attr]
    end

    it "gives a type whose identity accepts only an id a datasource looked up by id, and the scope one that takes nothing" do
      expect(statements(derive(create: {}), :Datasource)).to eq [TerraformGenerator::Datasource.new(%w[id], [[:kinds, "{thing_id}"]])]
      expect(derive(name: :project).statements.first).to eq TerraformGenerator::Datasource.new([], [[:kinds, "{project_id}"]])
    end
  end

  describe "scope" do
    it "keeps the scope's parameter in paths, and makes it no attribute" do
      type = derive(name: :project)
      expect([type.item, type.statements.grep(TerraformGenerator::Attr).map(&:name)]).to eq ["/project/{project_id}", %w[id]]
    end
  end

  describe "location" do
    it "makes {location} a required attribute that replaces the resource" do
      attr = derive_attr(:location, create: {}, item: "/location/{location}/thing/{thing_id}")
      expect(attr.to_h).to eq(name: "location", type: :str, flags: Set[:required, :replace], doc: "The location", default: nil, checks: [],
        why: [[:location, "{location}"], [:replace, "{location}"]])
    end
  end

  describe "parent_key" do
    it "makes a parent's parameter the attribute <parent>_id, checked and described by the parent's id" do
      type = derive(name: :parent_thing, create: {}, item: "/parent/{parent_reference}/thing/{thing_id}", paths: parent)
      attr = statements(type, :Attr).find { it.name == "parent_id" }
      expect(attr.to_h).to eq(name: "parent_id", type: :str, flags: Set[:required, :replace], doc: "ID of the parent", default: nil,
        checks: [call(:matches, "^pa[0-9a-z]{24}$")],
        why: [[:parent_key, "{parent_reference}"], [:replace, "{parent_reference}"], [:checks, "getParent.id"]])
      expect(type.item).to eq "/project/{project_id}/parent/{parent_id}/thing/{id}"
      expect(statements(type, :Create).first.path).to eq "/project/{project_id}/parent/{parent_id}/thing"
    end

    it "refuses a parameter whose path is not an item path" do
      expect_refusal("{parent_reference}: /project/{project_id}/parent/{parent_reference} is not an item path, so the parameter names no parent; give it a GET",
        name: :parent_thing, create: {}, item: "/parent/{parent_reference}/thing/{thing_id}")
    end

    it "refuses a parent whose GET returns no id, or that has no GET" do
      [{get: {operationId: "getParent", responses: {"200": {description: "A parent", **json(object)}}}}, {delete: {operationId: "deleteParent", responses: {}}}].each do |ops|
        paths = {"/parent/{parent_reference}" => path_item("/project/{project_id}/parent/{parent_reference}", **ops)}
        expect_refusal("/project/{project_id}/parent/{parent_reference}: no GET returns the parent's id, which the key is checked against; add one",
          name: :parent_thing, create: {}, item: "/parent/{parent_reference}/thing/{thing_id}", paths:)
      end
    end
  end

  describe "identity" do
    it "makes id a computed, stable attribute" do
      expect(derive_attr(:id, create: {}).to_h).to eq(name: "id", type: :str, flags: Set[:computed, :stable], doc: "Its description", default: nil, checks: [],
        why: [[:identity, "{thing_id}"], [:stable, "Thing.id"]])
    end

    it "refuses an item response without an id" do
      expect_refusal("getThing: the response has no id, by which the provider addresses the object; add it", create: {}, responses: {Thing: {description: "A thing", **json(object)}})
    end

    it "fills the name from the identity when the create is the POST on the item, with the parameter's checks" do
      type = derive(create: {}, on_item: true, item: "/thing/{thing_reference}")
      expect(statements(type, :Create).first.path).to eq "/project/{project_id}/thing/{name}"
      expect(statements(type, :Attr).find { it.name == "name" }.to_h).to eq(name: "name", type: :str, flags: Set[:required, :replace], doc: "The thing_reference",
        default: nil, checks: [call(:matches, "^[a-z0-9-]+$")],
        why: [[:identity, "{thing_reference}"], [:replace, "{thing_reference}"], [:checks, "{thing_reference}"]])
    end
  end

  describe "create_op" do
    it "takes the POST on the collection, with its body" do
      expect(statements(derive(create: {color: {type: "string", writeOnly: true}}), :Create))
        .to eq [TerraformGenerator::Create.new("POST", "/project/{project_id}/thing", ["color"], [[:create_op, "createThing"]])]
    end

    it "takes a create with no request body" do
      expect(statements(derive(paths: {"/thing" => {post: op("createThing")}}), :Create).first.body).to eq []
    end

    it "prefers the POST on the collection to the POST on the item" do
      expect(statements(derive(create: {}, ops: {post: op("updateThing")}), :Create).first.path).to eq "/project/{project_id}/thing"
    end

    it "accepts a create that returns the item schema's allOf base" do
      base = {type: "object", properties: {id: {type: "string", readOnly: true, description: "ID", example: "x"}}}
      responses = {Thing: {description: "A thing", **json(allOf: [{"$ref": "#/components/schemas/Base"}, {type: "object"}])}, Base: {description: "A base", **json("$ref": "#/components/schemas/Base")}}
      type = derive(create: {}, schemas: {Base: base}, responses:, paths: {"/thing" => {post: op("createThing", {}, response: "Base")}})
      expect(statements(type, :Create).first.why).to eq [[:create_op, "createThing"]]
    end
  end

  describe "union_collapse" do
    it "reads a create response that is a union of the item and an array of items as the item" do
      responses = {Things: {description: "One or more", **json(anyOf: [{"$ref": "#/components/schemas/Thing"}, {type: "array", items: {"$ref": "#/components/schemas/Thing"}}])}}
      schemas = {Thing: object({id: {type: "string", readOnly: true}})}
      type = derive(schemas:, responses: {Thing: {description: "A thing", **json("$ref": "#/components/schemas/Thing")}, **responses},
        paths: {"/thing" => {post: op("createThing", {}, response: "Things")}})
      expect(statements(type, :Create).first.why).to eq [[:create_op, "createThing"], [:union_collapse, "Things"]]
    end
  end

  describe "create_response" do
    it "refuses a create whose response is not the item" do
      responses = {Other: {description: "Another", **json(object({other: {type: "string"}}))}}
      expect_refusal(/createThing: the success response is not the item schema/, responses:, paths: {"/thing" => {post: op("createThing", {}, response: "Other")}})
    end
  end

  describe "crud_ops" do
    it "refuses a resource with no DELETE on its item path" do
      paths = {"/thing/{thing_id}" => path_item("/project/{project_id}/thing/{thing_id}", get: op("getThing"))}
      expect_refusal("/project/{project_id}/thing/{thing_id}: a resource needs a GET and a DELETE on its item path; add the DELETE", create: {}, paths:)
    end

    it "refuses a type that is neither a resource nor a datasource" do
      paths = {"/thing/{thing_id}" => path_item("/project/{project_id}/thing/{thing_id}", delete: {operationId: "deleteThing", responses: {"204": {description: "Deleted"}}})}
      expect_refusal("/project/{project_id}/thing/{thing_id}: neither a resource, which needs a create, nor a datasource, which needs a GET", paths:)
    end
  end

  describe "attribute_set" do
    it "merges a request property and a response property of one name, and leaves out deprecated ones and the request's readOnly ones" do
      type = derive(create: {color: {type: "string"}, old: {type: "string", deprecated: true}, echo: {type: "string", readOnly: true}},
        response: {color: {type: "string"}, gone: {type: "string", deprecated: true}})
      expect(statements(type, :Attr).map(&:name)).to eq %w[color id]
      expect(statements(type, :Create).first.body).to eq %w[color]
    end
  end

  describe "required" do
    it "requires a property the create body requires without a default" do
      attr = derive_attr(:color, create: {color: {type: "string", writeOnly: true}}, required: %w[color])
      expect([attr.flags, attr.why]).to eq [Set[:required, :replace, :write_only], [[:required, "createThing.color"], [:replace, "createThing.color"], [:write_only, "createThing.color"]]]
    end
  end

  describe "write_only" do
    it "replaces a write-only create input that no verb carries" do
      attr = derive_attr(:public_key, create: {public_key: {type: "string", writeOnly: true}})
      expect(attr.flags).to eq Set[:optional, :replace, :write_only]
    end
  end

  describe "computed" do
    it "computes a response property that no input carries" do
      attr = derive_attr(:state, response: {state: {type: "string", readOnly: true}}, item: "/thing/{thing_reference}")
      expect([attr.flags, attr.why]).to eq [Set[:computed], [[:computed, "Thing.state"]]]
    end

    it "computes an optional input the response echoes unless null clears it, and an input with a default, and never a required input" do
      create = {echoed: {type: "string"}, cleared: {type: "string", nullable: true}, defaulted: {type: "string", writeOnly: true, default: "x"}, needed: {type: "string"}}
      type = derive(create:, required: %w[needed], response: {echoed: {type: "string"}, cleared: {type: "string", nullable: true}, needed: {type: "string"}})
      expect(statements(type, :Attr).to_h { [it.name, it.flags] }).to include(
        "echoed" => Set[:optional, :computed, :replace, :stable],
        "cleared" => Set[:optional, :replace, :nullable],
        "defaulted" => Set[:optional, :computed, :replace, :stable, :write_only],
        "needed" => Set[:required, :replace],
      )
    end
  end

  describe "default" do
    it "makes a request property's default the framework default" do
      create = {s: {type: "string", default: "x"}, i: {type: "integer", default: 2}, b: {type: "boolean", default: false}}
      type = derive(create:, response: create.transform_values { it.except(:default) })
      expect(statements(type, :Attr).filter_map(&:default)).to eq [
        call(:default_bool, false), call(:default_int, 2), call(:default_string, "x"),
      ]
      expect(statements(type, :Attr).find { it.name == "s" }.why).to eq [[:default, "createThing.s"], [:replace, "createThing.s"], [:stable, "createThing.s"]]
    end

    it "refuses a default the framework cannot hold" do
      expect_refusal("createThing.ratio: a default of 0.5 has no framework default; remove it", create: {ratio: {type: "integer", default: 0.5}}, response: {ratio: {type: "integer"}})
    end
  end

  describe "sensitive" do
    it "makes an attribute sensitive for format: password on the request or the response" do
      type = derive(create: {secret: {type: "string", format: "password", writeOnly: true}}, response: {key: {type: "string", format: "password", readOnly: true}})
      expect(statements(type, :Attr).to_h { [it.name, it.flags.include?(:sensitive)] }).to eq("id" => false, "key" => true, "secret" => true)
    end
  end

  describe "replace" do
    it "replaces a create input that no verb owns, and not one a verb owns or an input only a verb carries" do
      type = derive(create: {fixed: {type: "string"}, moved: {type: "string"}}, response: {fixed: {type: "string"}, moved: {type: "string"}, later: {type: "string"}},
        ops: {patch: verb("updateThing", moved: {type: "string"}, later: {type: "string"})})
      expect(statements(type, :Attr).to_h { [it.name, it.flags.include?(:replace)] }).to eq("fixed" => true, "id" => false, "later" => false, "moved" => false)
    end
  end

  describe "stable" do
    it "keeps an input and an x-immutable output in plans, and not another computed output" do
      response = {color: {type: "string"}, net: {type: "string", readOnly: true, "x-immutable": true}, state: {type: "string", readOnly: true}}
      type = derive(create: {color: {type: "string"}}, response:)
      expect(statements(type, :Attr).to_h { [it.name, it.why.assoc(:stable)] })
        .to eq("color" => [:stable, "createThing.color"], "id" => [:stable, "Thing.id"], "net" => [:stable, "Thing.net"], "state" => nil)
    end
  end

  describe "attr_type" do
    it "maps types and string formats by the table, nullable to a flag, and reads any other format as documentation" do
      response = {
        s: {type: "string"}, i: {type: "integer"}, b: {type: "boolean"}, t: {type: "string", format: "date-time"},
        c: {type: "string", format: "cidr"}, p: {type: "string", format: "port-range"}, ip: {type: "string", format: "ipv4", nullable: true},
        n: {type: "integer", format: "date-time"}, l: {type: "array", items: {type: "string"}}, u: {type: "array", uniqueItems: true, items: {type: "integer"}},
        m: {type: "object", additionalProperties: {type: "object", additionalProperties: {type: "string"}}},
      }
      type = derive(response: response.transform_values { {readOnly: true, **it} }, item: "/thing/{thing_reference}")
      expect(statements(type, :Attr).to_h { [it.name, it.type] }).to eq(
        "b" => :boolean, "c" => call(:string_of, "cidr"), "i" => :i64, "id" => :str, "ip" => :str,
        "l" => call(:list_of, :str), "m" => call(:map_of, call(:map_of, :str)), "n" => :i64, "p" => call(:string_of, "port-range"),
        "s" => :str, "t" => :timestamp, "u" => call(:set_of, :i64),
      )
      expect(statements(type, :Attr).find { it.name == "ip" }.to_h.values_at(:flags, :why)).to eq [Set[:computed, :nullable], [[:computed, "Thing.ip"], [:attr_type, "Thing.ip"]]]
    end

    it "takes the request property's schema only when no response property exists" do
      attr = derive_attr(:size, create: {size: {type: "integer", writeOnly: true}})
      expect([attr.type, attr.why.assoc(:attr_type)]).to eq [:i64, [:attr_type, "createThing.size"]]
    end
  end

  describe "closed_types" do
    [
      ["a union", {anyOf: [{type: "string"}, {type: "integer"}]}],
      ["a free-form object", {type: "object"}],
      ["binary content", {type: "string", format: "binary"}],
      ["a number", {type: "number"}],
      ["an unknown type", {type: "null"}],
      ["a format without a type", {format: "cidr"}],
    ].each do |what, schema|
      it "refuses #{what}" do
        expect_refusal(/\AThing.odd: no attribute type fits; give it one type/, response: {odd: {readOnly: true, **schema}}, item: "/thing/{thing_reference}")
      end
    end
  end

  describe "nesting" do
    def nested(**part) = {type: "object", properties: {name: {type: "string", description: "Its name"}, **part}}

    it "nests a response object to any depth, leaving out deprecated properties" do
      inner = {description: "Inner", **nested(deeper: {description: "Deeper", **nested})}
      part = {readOnly: true, description: "A part", **nested(inner:, old: {type: "string", deprecated: true, description: "Old"}, tags: {type: "array", items: {type: "string"}, description: "Tags"})}
      attr = derive_attr(:part, response: {part: {"$ref": "#/components/schemas/Part"}}, schemas: {Part: part}, item: "/thing/{thing_reference}")
      inner = attr.type.attrs.first
      expect([attr.type.var, attr.type.why, attr.type.attrs.map(&:name), inner.type.attrs.map(&:name), inner.type.attrs.first.type.var, inner.type.attrs.first.why])
        .to eq ["o_part", [[:nesting, "Thing.part"]], %w[inner name tags], %w[deeper name], "o_part_inner_deeper", [[:computed, "Part.inner.deeper"], [:attr_type, "Part.inner.deeper"]]]
      expect(attr.type.attrs.last.why).to eq [[:computed, "Part.tags"], [:attr_type, "Part.tags"]]
    end

    it "nests an array of objects as a list, or a set under uniqueItems, naming its properties after the schema" do
      response = {parts: {type: "array", readOnly: true, items: {"$ref": "#/components/schemas/Part"}}, bag: {type: "array", uniqueItems: true, readOnly: true, items: nested}}
      type = derive(response:, schemas: {Part: nested}, item: "/thing/{thing_reference}")
      parts, bag = %w[parts bag].map { |n| statements(type, :Attr).find { it.name == n }.type }
      expect([parts.kind, parts.var, parts.why, parts.attrs.first.why, bag.kind]).to eq [:list, "o_parts", [[:nesting, "Thing.parts"]], [[:computed, "Part.name"]], :set]
    end

    it "makes an input object's properties required or optional, with their checks" do
      part = nested(code: {type: "string", pattern: "^[a-z]+$", description: "Its code", format: "password", nullable: true}).merge(required: %w[name])
      attrs = derive_attr(:part, create: {part: {writeOnly: true, **part}}).type.attrs
      expect(attrs.map { it.to_h.values_at(:name, :flags, :checks, :why) }).to eq [
        ["code", Set[:optional, :sensitive, :nullable], [call(:matches, "^[a-z]+$")],
          [[:optional, "createThing.part.code"], [:sensitive, "createThing.part.code"], [:attr_type, "createThing.part.code"], [:checks, "createThing.part.code"]]],
        ["name", Set[:required], [], [[:required, "createThing.part.name"]]],
      ]
    end

    it "nests an input object to any depth, naming each object's variable after the objects it is in" do
      part = nested(inner: {description: "Inner", **nested(deeper: {description: "Deeper", **nested})}, inners: {type: "array", items: nested, description: "Inners"})
      outer = derive_attr(:part, create: {part: {writeOnly: true, **part}}).type
      inner = outer.attrs.find { it.name == "inner" }
      expect([outer.var, inner.type.var, inner.why, inner.type.attrs.first.type.var, outer.attrs.find { it.name == "inners" }.type.kind])
        .to eq ["o_part", "o_part_inner", [[:optional, "createThing.part.inner"], [:attr_type, "createThing.part.inner"]], "o_part_inner_deeper", :list]
    end
  end

  describe "ids" do
    def part = {"$ref": "#/components/schemas/Part"}

    def parts(**schema) = {type: "array", readOnly: true, items: part, description: "Parts", **schema}

    # Besides thing, a type part, whose item GET's response extends the
    # schema Part; a type bit, whose response is the schema Bit, which has
    # no id; a type blob, whose GET returns no content; and a type gone,
    # which has no GET.
    def typed(response:, create: nil)
      paths = {
        "/part/{part_id}" => path_item("/project/{project_id}/part/{part_id}", get: op("getPart", response: "PartDetailed")),
        "/bit/{bit_id}" => path_item("/project/{project_id}/bit/{bit_id}", get: op("getBit", response: "Bit")),
        "/blob/{blob_id}" => path_item("/project/{project_id}/blob/{blob_id}", get: {operationId: "getBlob", responses: {"200": {description: "A blob"}}}),
        "/gone/{gone_id}" => path_item("/project/{project_id}/gone/{gone_id}", delete: {operationId: "deleteGone", responses: {"204": {description: "Deleted"}}}),
      }
      responses = {
        PartDetailed: {description: "A part", **json({type: "object", allOf: [part, object({size: {type: "integer"}})]})},
        Bit: {description: "A bit", **json({"$ref": "#/components/schemas/Bit"})},
      }
      schemas = {
        Part: object({id: {type: "string", readOnly: true, pattern: "^pt[0-9a-z]{24}$"}}, description: "A part", readOnly: true),
        Bit: object({name: {type: "string", readOnly: true}}, description: "A bit", readOnly: true),
        PartPlus: {type: "object", readOnly: true, description: "A part and more", allOf: [part]},
      }
      derive(response:, create:, paths:, responses:, schemas:, item: "/thing/{thing_reference}")
    end

    def attrs(type) = statements(type, :Attr).to_h { [it.name, it] }

    it "holds the id of a response object whose schema is a type's item schema, or the ids of an array of them, in a list or a set" do
      type = typed(response: {part:, plus: {"$ref": "#/components/schemas/PartPlus"}, parts:, bags: parts(uniqueItems: true), bit: {"$ref": "#/components/schemas/Bit"}})
      expect(attrs(type).except("id", "bit").transform_values { it.to_h.values_at(:type, :flags, :checks, :why) }).to eq(
        "part_id" => [:str, Set[:computed], [call(:ids_of, "part")], [[:computed, "Thing.part"], [:ids, "PartDetailed.id"]]],
        "plus_id" => [:str, Set[:computed], [call(:ids_of, "plus")], [[:computed, "Thing.plus"], [:ids, "PartDetailed.id"]]],
        "part_ids" => [call(:list_of, :str), Set[:computed], [call(:ids_of, "parts")], [[:computed, "Thing.parts"], [:attr_type, "Thing.parts"], [:ids, "PartDetailed.id"]]],
        "bag_ids" => [call(:set_of, :str), Set[:computed], [call(:ids_of, "bags")], [[:computed, "Thing.bags"], [:attr_type, "Thing.bags"], [:ids, "PartDetailed.id"]]],
      )
      expect(attrs(type)["bit"].type.attrs.map(&:name)).to eq %w[name]
    end

    it "holds ids inside a nested object, sorting its attributes by their new names, and nests an input whatever its schema" do
      holder = {type: "object", readOnly: true, description: "Holder", properties: {part_x: {type: "string", description: "X"}, parts:}}
      type = typed(response: {holder:}, create: {input: {type: "object", writeOnly: true, description: "Input", allOf: [part]}})
      expect(attrs(type)["holder"].type.attrs.map { it.to_h.values_at(:name, :checks, :why) }).to eq [
        ["part_ids", [call(:ids_of, "parts")], [[:computed, "Thing.holder.parts"], [:attr_type, "Thing.holder.parts"], [:ids, "PartDetailed.id"]]],
        ["part_x", [], [[:computed, "Thing.holder.part_x"]]],
      ]
      expect(attrs(type)["input"].type.attrs.map(&:name)).to eq %w[id]
    end

    it "refuses a name that it gives when that name is already a property's, alongside or nested" do
      expect { typed(response: {parts:, part_ids: {type: "string", readOnly: true}}) }
        .to raise_error(TerraformGenerator::SpecError, "Thing.parts: rule ids names it part_ids, which is already a property; rename one")
      holder = {type: "object", readOnly: true, description: "Holder", properties: {parts:, part_ids: {type: "string", description: "IDs"}}}
      expect { typed(response: {holder:}) }
        .to raise_error(TerraformGenerator::SpecError, "Thing.holder.parts: rule ids names it part_ids, which is already a property; rename one")
    end
  end

  describe "checks" do
    def checked(name, **parts) = derive_attr(name, **parts).to_h.values_at(:checks, :why)

    it "takes the response's enum where the request is looser" do
      create = {protocol: {type: "string", enum: %w[tcp TCP udp UDP]}}
      expect(checked(:protocol, create:, response: {protocol: {type: "string", enum: %w[tcp udp]}}))
        .to eq [[call(:one_of, "tcp", "udp")], [[:computed, "Thing.protocol"], [:replace, "createThing.protocol"], [:stable, "createThing.protocol"], [:checks, "Thing.protocol"]]]
    end

    it "makes bounds, lengths and patterns into checks, taking each keyword from the request before the response, and checks no other type" do
      create = {a: {type: "integer", minimum: 0, maximum: 23}, b: {type: "integer", minimum: 1}, c: {type: "integer", maximum: 9}, d: {type: "string", maxLength: 63, pattern: "^[a-z]+$"},
                e: {type: "string", minLength: 2, maxLength: 3}, f: {type: "string", minLength: 1}, g: {type: "boolean", enum: [true]}}
      type = derive(create:, response: create.transform_values { {**it, pattern: "^.$"} })
      expect(statements(type, :Attr).to_h { [it.name, it.checks] }).to eq(
        "a" => [call(:matches, "^.$"), call(:at_least, 0), call(:at_most, 23)], "b" => [call(:matches, "^.$"), call(:at_least, 1)], "c" => [call(:matches, "^.$"), call(:at_most, 9)],
        "d" => [call(:matches, "^[a-z]+$"), call(:at_most, 63)], "e" => [call(:matches, "^.$"), call(:at_least, 2), call(:at_most, 3)], "f" => [call(:matches, "^.$"), call(:at_least, 1)], "g" => [], "id" => [],
      )
    end

    it "skips a pattern RE2 cannot compile, and says so" do
      create = {a: {type: "string", pattern: "^(?!x)[a-z]+$", writeOnly: true}, b: {type: "string", pattern: "^(.)\\1$", writeOnly: true}}
      type = derive(create:)
      expect(statements(type, :Attr).to_h { [it.name, [it.checks, it.why.assoc(:checks)]] }).to include(
        "a" => [[], [:checks, "createThing.a!re2"]],
        "b" => [[], [:checks, "createThing.b!re2"]],
      )
    end

    it "checks no output" do
      expect(checked(:state, response: {state: {type: "string", readOnly: true, enum: %w[on off]}}, item: "/thing/{thing_reference}")).to eq [[], [[:computed, "Thing.state"]]]
    end
  end

  describe "doc" do
    it "takes the response property's description, else the request property's, else the parameter's, and names any but the first" do
      type = derive(create: {color: {type: "string", description: "Requested color"}, size: {type: "string", description: "Requested size"}},
        response: {color: {type: "string", description: "Color"}, size: {type: "string", description: nil}}, item: "/location/{location}/thing/{thing_id}")
      expect(statements(type, :Attr).to_h { [it.name, [it.doc, it.why.assoc(:doc)]] }).to include(
        "color" => ["Color", nil], "size" => ["Requested size", [:doc, "createThing.size"]], "location" => ["The location", nil],
      )
    end
  end

  describe "described" do
    it "refuses an attribute without a description" do
      expect_refusal("Thing.state: no description; add one", response: {state: {type: "string", readOnly: true, description: nil}}, item: "/thing/{thing_reference}")
    end

    it "refuses a type without a description, naming its item response" do
      expect_refusal("Thing: no description; add one", item: "/thing/{thing_reference}", responses: {Thing: json(object({id: {type: "string", readOnly: true}}))})
    end
  end

  describe "verb_candidates" do
    it "takes the PATCH on the item and each POST or PATCH with a body on a direct subroute, but no action, read, deprecated operation or child collection" do
      paths = {
        "/thing/{thing_id}/rename" => {post: verb("renameThing", color: {type: "string"})},
        "/thing/{thing_id}/restart" => {post: op("restartThing")},
        "/thing/{thing_id}/log" => {get: op("getThingLog")},
        "/thing/{thing_id}/old" => {post: verb("oldThing", color: {type: "string"}).merge(deprecated: true)},
        "/thing/{thing_id}/part" => {post: verb("createPart", color: {type: "string"})},
        "/thing/{thing_id}/part/{part_id}" => {get: op("getPart")},
      }
      type = derive(create: {color: {type: "string"}}, response: {color: {type: "string"}}, ops: {patch: verb("updateThing", color: {type: "string"})}, paths:)
      expect(statements(type, :Verb).map(&:to_h)).to eq [{method: "PATCH", path: "", body: %w[color], why: [[:verb_candidates, "updateThing"]]}]
      expect(statements(type, :Dropped)).to eq [TerraformGenerator::Dropped.new("renameThing", [[:verb_owner, "renameThing"]])]
    end

    it "sets aside a candidate whose body carries a property that is neither an input nor in the response, but not a writeOnly one" do
      paths = {"/thing/{thing_id}/attach" => {post: verb("attachThing", other: {type: "string"})}, "/thing/{thing_id}/seal" => {post: verb("sealThing", key: {type: "string", writeOnly: true})}}
      type = derive(create: {}, paths:)
      expect(type.statements.grep(TerraformGenerator::Dropped).map(&:to_h) + statements(type, :Verb).map(&:path))
        .to eq [{operation: "attachThing", why: [[:verb_candidates, "attachThing"]]}, "/seal"]
    end
  end

  describe "item_post_verb" do
    it "makes the POST on the item a candidate when the create is on the collection" do
      type = derive(create: {color: {type: "string"}}, response: {color: {type: "string"}}, ops: {post: verb("updateThing", color: {type: "string"})})
      expect(statements(type, :Verb)).to eq [TerraformGenerator::Verb.new("POST", "", %w[color], [[:item_post_verb, "updateThing"]])]
    end
  end

  describe "merge_subroute" do
    it "sets aside a PATCH on a subroute" do
      type = derive(create: {color: {type: "string"}}, response: {color: {type: "string"}}, paths: {"/thing/{thing_id}/config" => {patch: verb("patchThingConfig", color: {type: "string"})}})
      expect(type.statements.last).to eq TerraformGenerator::Dropped.new("patchThingConfig", [[:merge_subroute, "patchThingConfig"]])
    end
  end

  describe "name_carrier" do
    it "sets aside a subroute body that carries the name with other properties, but not one carrying the name alone" do
      paths = {"/thing/{thing_id}/copy" => {post: verb("copyThing", name: {type: "string"}, color: {type: "string"})}, "/thing/{thing_id}/rename" => {post: verb("renameThing", name: {type: "string"})}}
      type = derive(create: {name: {type: "string"}, color: {type: "string"}}, response: {name: {type: "string"}, color: {type: "string"}}, paths:)
      expect(type.statements.last(2).map(&:to_h)).to eq [
        {operation: "copyThing", why: [[:name_carrier, "copyThing"]]},
        {method: "POST", path: "/rename", body: %w[name], why: [[:verb_candidates, "renameThing"]]},
      ]
    end
  end

  describe "verb_order" do
    let(:paths) do
      %w[resize upgrade].to_h { ["/thing/{thing_id}/#{it}", {post: verb("#{it}Thing", it.to_sym => {type: "string"})}] }
    end

    def verbs(facts) = statements(derive(facts, create: {}, response: {resize: {type: "string"}, upgrade: {type: "string"}, size: {type: "string"}}, paths:, ops: {patch: verb("updateThing", size: {type: "string"})}), :Verb)

    it "runs the item's verbs, then the subroutes by path" do
      expect(verbs({}).map(&:path)).to eq ["", "/resize", "/upgrade"]
    end

    it "runs the verbs the definition orders first, and says so" do
      expect(verbs(order: %i[upgrade]).map { [it.path, it.why] }).to eq [
        ["/upgrade", [[:verb_order, "definitions.rb"], [:verb_candidates, "upgradeThing"]]], ["", [[:verb_candidates, "updateThing"]]], ["/resize", [[:verb_candidates, "resizeThing"]]],
      ]
    end
  end

  describe "verb_owner" do
    it "gives each attribute to the first verb that carries it, and drops a verb left owning nothing" do
      paths = {"/thing/{thing_id}/toggle" => {post: verb("toggleThing", on: {type: "boolean"})}}
      response = {on: {type: "boolean"}, size: {type: "string"}}
      type = derive(create: {size: {type: "string"}}, response:, paths:, ops: {patch: verb("updateThing", on: {type: "boolean"}, size: {type: "string"})})
      expect(type.statements.last(2)).to eq [
        TerraformGenerator::Verb.new("PATCH", "", %w[on size], [[:verb_candidates, "updateThing"]]),
        TerraformGenerator::Dropped.new("toggleThing", [[:verb_owner, "toggleThing"]]),
      ]
    end
  end

  describe "lifecycle" do
    it "gives the values in which the object is pending and those in which it failed, from the property x-lifecycle marks" do
      state = {type: "string", readOnly: true, enum: %w[running creating deleting broken], "x-lifecycle": {pending: %w[deleting creating], failed: %w[broken]}}
      type = derive(create: {}, response: {state:})
      expect(type.statements.grep(TerraformGenerator::Pending) + type.statements.grep(TerraformGenerator::Failed)).to eq [
        TerraformGenerator::Pending.new("state", %w[creating deleting], [[:lifecycle, "Thing.state"]]),
        TerraformGenerator::Failed.new("state", %w[broken], [[:lifecycle, "Thing.state"]]),
      ]
    end

    it "gives no failed values when x-lifecycle lists none, and no pending values when it lists none" do
      pending = derive(create: {}, response: {state: {type: "string", readOnly: true, enum: %w[a], "x-lifecycle": {pending: %w[a]}}})
      failed = derive(create: {}, response: {state: {type: "string", readOnly: true, enum: %w[a], "x-lifecycle": {failed: %w[a]}}})
      expect([pending, failed].map { |type| type.statements.map(&:class) & [TerraformGenerator::Pending, TerraformGenerator::Failed] })
        .to eq [[TerraformGenerator::Pending], [TerraformGenerator::Failed]]
    end
  end

  describe "lifecycle_enum" do
    it "refuses x-lifecycle on two properties" do
      marked = {type: "string", readOnly: true, enum: %w[a], "x-lifecycle": {pending: %w[a]}}
      expect_refusal("getThing: x-lifecycle marks a and b; mark one", create: {}, response: {a: marked, b: marked})
    end

    it "refuses x-lifecycle on a property that is not readOnly or whose enum lacks a listed value" do
      expect_refusal("Thing.state: x-lifecycle needs a readOnly property whose enum lists creating, broken",
        create: {}, response: {state: {type: "string", readOnly: true, enum: %w[creating], "x-lifecycle": {pending: %w[creating], failed: %w[broken]}}})
      expect_refusal(/Thing.state: x-lifecycle needs a readOnly/, create: {state: {type: "string"}}, response: {state: {type: "string", enum: %w[a], "x-lifecycle": {pending: %w[a]}}})
    end

    it "refuses x-lifecycle that is not an object whose pending and failed members list strings" do
      [true, {pending: "a"}, {pendng: %w[a]}, {failed: [1]}].each do |lifecycle|
        expect_refusal("Thing.state: x-lifecycle needs an object whose pending and failed members list strings",
          create: {}, response: {state: {type: "string", readOnly: true, enum: %w[a], "x-lifecycle": lifecycle}})
      end
    end
  end

  describe "typed_allof" do
    it "refuses an allOf member without type: object" do
      expect_refusal("Thing: an allOf member lacks type: object; add it", create: {}, responses: {Thing: {description: "A thing", **json(allOf: [object({id: {type: "string", readOnly: true}}), {properties: {}}])}})
    end
  end

  describe "response_direction" do
    it "refuses a response property that is neither readOnly nor accepted by an input" do
      expect_refusal("Thing.color: neither readOnly nor accepted by an input; mark it readOnly, or accept it in the create or a verb", create: {}, response: {color: {type: "string"}})
    end
  end

  describe "input_echo" do
    it "refuses a body property that is neither in the response nor writeOnly" do
      expect_refusal("createThing.public_key: neither in the response nor writeOnly; mark it writeOnly or echo it", create: {public_key: {type: "string"}})
    end
  end

  describe "echo_agreement" do
    it "refuses a request that accepts less than the response returns, in type, format or enum" do
      [
        [{type: "integer"}, {type: "string"}],
        [{type: "string", format: "cidr"}, {type: "string"}],
        [{type: "string", enum: %w[a]}, {type: "string", enum: %w[a b]}],
        [{type: "string", enum: %w[a]}, {type: "string"}],
        [{type: "array", items: {type: "integer"}}, {type: "array", items: {type: "string"}}],
      ].each do |req, resp|
        expect_refusal("createThing.v: accepts less than Thing.v returns; make the request accept every value the response allows", create: {v: req}, response: {v: resp})
      end
    end

    it "accepts a looser request, and nullable on one side only" do
      create = {
        config: {type: "object", additionalProperties: {anyOf: [{type: "string"}, {type: "number"}]}},
        mode: {type: "string", enum: %w[a b c]}, note: {type: "string", nullable: true}, cidr: {type: "string"},
      }
      response = {config: {type: "object", additionalProperties: {type: "string"}}, mode: {type: "string", enum: %w[a b]}, note: {type: "string"}, cidr: {type: "string", format: "cidr"}}
      expect(statements(derive(create:, response:), :Attr).map(&:name)).to eq %w[cidr config id mode note]
    end
  end

  describe "immutable_readonly" do
    it "refuses x-immutable on a property that is not readOnly" do
      expect_refusal("Thing.net: x-immutable without readOnly; it marks outputs only", create: {net: {type: "string"}}, response: {net: {type: "string", "x-immutable": true}})
    end
  end

  describe "example" do
    it "takes each attribute's example from the request property, else the key, else the response property" do
      create = {color: {type: "string", example: "red"}, size: {type: "string", example: nil}, note: {type: "string", example: nil, writeOnly: true}, location: {type: "string", example: "here"}}
      response = {color: {type: "string", example: "blue"}, size: {type: "string", example: "big"}, state: {type: "string", readOnly: true, example: false}, location: {type: "string", example: "elsewhere"}}
      type = derive(create:, response:, item: "/location/{location}/thing/{thing_id}")
      expect(type.examples).to eq("color" => "red", "id" => "x", "location" => "here", "size" => "big", "state" => false)
    end

    it "takes a parent key's example from the parent's id, and the name an identity fills from its examples entry named name, ahead of the response property" do
      id = {type: "string", readOnly: true, example: "pa1", description: "ID of the parent"}
      paths = {"/parent/{parent_reference}" => path_item("/project/{project_id}/parent/{parent_reference}", get: {operationId: "getParent", responses: {"200": {description: "A parent", **json(object({id:}))}}})}
      item = "/parent/{parent_reference}/thing/{thing_reference}"
      response = {name: {type: "string", example: "other"}}
      type = derive(name: :parent_thing, create: {}, on_item: true, item:, paths:, response:, ops: {parameters: identity_examples(item, id: {value: "th1"}, name: {value: "my-thing"})})
      expect([type.examples, type.references]).to eq [{"id" => "x", "name" => "my-thing", "parent_id" => "pa1"}, {"parent_id" => "parent"}]
    end

    it "takes the inputs the create body's example sets, and their values, ahead of the property examples" do
      create = {color: {type: "string", example: "red"}, size: {type: "string", example: "big"}, echo: {type: "string", readOnly: true}, part: object({name: {type: "string"}}, writeOnly: true)}
      body = {color: "blue", echo: "e", part: {name: "p"}, state: "up", size: nil}
      type = derive(create:, example: body, required: %w[color], response: create.except(:part), item: "/location/{location}/thing/{thing_id}")
      expect([type.example_inputs, type.examples.except("id")]).to eq [%w[color location part], {"color" => "blue", "echo" => "x", "location" => "x", "part" => {"name" => "p"}, "size" => "big"}]
    end

    it "sets only the required inputs where the create body has no example" do
      expect(derive(create: {color: {type: "string"}, size: {type: "string"}}, required: %w[color], response: {color: {type: "string"}, size: {type: "string"}}).example_inputs).to eq %w[color]
    end

    it "refers an input the example sets to the one other type whose id pattern is its pattern" do
      responses = {one: "^on$", two: "^tw$", three: "^tw$"}.to_h { |name, pattern| [name, {description: name, **json(object({id: {type: "string", readOnly: true, pattern:}}))}] }
      paths = %w[one two three].to_h { ["/#{it}/{#{it}_id}", path_item("/project/{project_id}/#{it}/{#{it}_id}", get: op("get#{it}", response: it))] }
      paths["/gone/{gone_id}"] = path_item("/project/{project_id}/gone/{gone_id}", delete: op("deleteGone"))
      create = {one_id: {type: "string", pattern: "^on$"}, twin_id: {type: "string", pattern: "^tw$"}, spare_id: {type: "string", pattern: "^on$"}, set_id: {type: "string", pattern: "^on$"}, plain: {type: "string"}}
      type = derive(create:, required: %w[one_id twin_id plain], example: {set_id: "on"}, response: create, paths:, responses:)
      expect(type.references).to eq("one_id" => "one", "set_id" => "one")
    end
  end

  describe "examples" do
    it "refuses a required create input or an id without an example" do
      expect_refusal("createThing.color: no example; add one to each", create: {color: {type: "string", writeOnly: true, example: nil}}, required: %w[color])
      responses = {Thing: {description: "A thing", **json(type: "object", properties: {id: {type: "string", readOnly: true, description: "ID"}})}}
      expect_refusal("Thing.id: no example; add one to each", create: {}, responses:)
    end

    it "refuses a name the identity fills whose examples have no entry named name" do
      params = identity_examples("/thing/{thing_reference}", id: {value: "th1"})
      expect_refusal("{thing_reference}: no example; add one to each", create: {}, on_item: true, item: "/thing/{thing_reference}", ops: {parameters: params})
    end

    it "takes the response property's example where the request property has none" do
      expect(derive_attr(:color, create: {color: {type: "string", example: nil}}, required: %w[color], response: {color: {type: "string"}}).flags).to eq Set[:required, :replace]
    end

    it "takes false as an example" do
      expect(derive_attr(:on, create: {on: {type: "boolean", example: false, writeOnly: true}}, required: %w[on]).flags).to eq Set[:required, :replace, :write_only]
    end
  end

  describe "special_cases" do
    it "names each definition key and each clause with the types it shaped" do
      api = TerraformGenerator::Api.new(thing(create: {color: {type: "string"}}, response: {color: {type: "string"}, size: {type: "string"}},
        ops: {post: verb("updateThing", color: {type: "string"})}, paths: {"/thing/{thing_id}/resize" => {post: verb("resizeThing", size: {type: "string"})}}))
      expect(TerraformGenerator.special_cases(api, {thing: {order: %i[resize]}})).to eq("definitions order" => %i[thing], "item_post_verb" => %i[thing])
    end

    it "counts nothing for the definitions as they stand" do
      expect(TerraformGenerator.special_cases).to eq({})
    end
  end
end
