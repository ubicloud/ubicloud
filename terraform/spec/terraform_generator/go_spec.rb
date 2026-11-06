# frozen_string_literal: true

RSpec.describe TerraformGenerator::Go do
  def literal(v) = described_class.literal(v)

  def statement(s) = described_class.statement("t", s)

  def attr(name, type = :str, flags = Set[:computed], default: nil, checks: [], why: [[:computed, "Thing.#{name}"]])
    TerraformGenerator::Attr.new(name:, type:, flags:, doc: "Its #{name}", default:, checks:, why:)
  end

  describe ".literal" do
    it "writes calls and symbols in lower camel case, a nested object as its kind's type, and flags joined by |" do
      expect(literal(call(:list_of, call(:map_of, :str)))).to eq "listOf(mapOf(str))"
      expect(literal(call(:one_of, "tcp", 1, true, false))).to eq 'oneOf("tcp", 1, true, false)'
      expect(%i[single list set].map { literal(TerraformGenerator::Nested.new(it, "o_part", [], [])) }).to eq %w[single(o_part) listOf(o_part) setOf(o_part)]
      expect(literal(Set[:optional, :computed, :write_only])).to eq "optional|computed|writeOnly"
    end

    it "quotes a string as JSON, and one with a backslash raw where a raw string can hold it" do
      expect([%(say "hi"), "a\nb\tc", "café ☃", "^\\d+$", "a\\b`c", "a\\b\nc"].map { literal(it) })
        .to eq [%("say \\"hi\\""), %("a\\nb\\tc"), %("café ☃"), "`^\\d+$`", %("a\\\\b`c"), %("a\\\\b\\nc")]
    end

    it "refuses a value it has no form for" do
      expect { literal(nil) }.to raise_error(NoMatchingPatternError)
    end
  end

  describe ".statement" do
    it "calls the method named after the record's class with its comment above, leaving out nil and spreading a last Array" do
      expect([
        TerraformGenerator::Create.new("POST", "/project/{project_id}/thing", %w[color size], [[:create_op, "createThing"], [:union_collapse, "Things"]]),
        TerraformGenerator::Datasource.new(%w[id name], [[:kinds, "{thing_reference}"]]),
        TerraformGenerator::Datasource.new([], [[:kinds, "{project_id}"]]),
        TerraformGenerator::Pending.new("state", %w[creating deleting], [[:lifecycle, "Thing.state"]]),
        TerraformGenerator::Failed.new("state", ["no capacity available"], [[:lifecycle, "Thing.state"]]),
        attr("state"),
        attr("port_range", call(:string_of, "port-range"), Set[:optional, :computed, :stable], default: call(:default_string, "0..65535"),
          checks: [call(:matches, "^\\d+(\\.\\.\\d+)?$")], why: [[:default, "createThing.port_range"], [:stable, "createThing.port_range"], [:checks, "createThing.port_range"], [:attr_type, "Thing.port_range"]]),
        TerraformGenerator::Verb.new("PATCH", "", %w[color], [[:verb_candidates, "updateThing"]]),
      ].map { statement(it) }).to eq [
        ["// create_op@createThing union_collapse@Things", 't.create("POST", "/project/{project_id}/thing", "color", "size")'],
        ["// kinds@{thing_reference}", 't.datasource("id", "name")'],
        ["// kinds@{project_id}", "t.datasource()"],
        ["// lifecycle@Thing.state", 't.pending("state", "creating", "deleting")'],
        ["// lifecycle@Thing.state", 't.failed("state", "no capacity available")'],
        ["// computed@Thing.state", 't.attr("state", str, computed, "Its state")'],
        ["// default,stable,checks@createThing.port_range attr_type@Thing.port_range",
          't.attr("port_range", stringOf("port-range"), optional|computed|stable, "Its port_range", defaultString("0..65535"), matches(`^\d+(\.\.\d+)?$`))'],
        ["// verb_candidates@updateThing", 't.verb("PATCH", "", "color")'],
      ]
    end

    it "builds a nested object before the attribute that uses it" do
      nested = TerraformGenerator::Nested.new(:list, "o_nics", [attr("mac", why: [[:computed, "Nic.mac"]])], [[:nesting, "PrivateSubnet.nics"]])
      expect(statement(attr("nics", nested, why: [[:computed, "PrivateSubnet.nics"]]))).to eq [
        "// nesting@PrivateSubnet.nics",
        "o_nics := object()",
        "// computed@Nic.mac",
        'o_nics.attr("mac", str, computed, "Its mac")',
        "// computed@PrivateSubnet.nics",
        't.attr("nics", listOf(o_nics), computed, "Its nics")',
      ]
    end

    it "builds an object nested in a nested object before the outer object's attribute that uses it" do
      auth = TerraformGenerator::Nested.new(:single, "o_options_auth", [attr("token", :str, Set[:required], why: [[:required, "createThing.options.auth.token"]])],
        [[:nesting, "createThing.options.auth"]])
      options = TerraformGenerator::Nested.new(:single, "o_options", [attr("auth", auth, Set[:optional], why: [[:optional, "createThing.options.auth"]])], [[:nesting, "createThing.options"]])
      expect(statement(attr("options", options, Set[:optional], why: [[:optional, "createThing.options"]]))).to eq [
        "// nesting@createThing.options",
        "o_options := object()",
        "// nesting@createThing.options.auth",
        "o_options_auth := object()",
        "// required@createThing.options.auth.token",
        'o_options_auth.attr("token", str, required, "Its token")',
        "// optional@createThing.options.auth",
        'o_options.attr("auth", single(o_options_auth), optional, "Its auth")',
        "// optional@createThing.options",
        't.attr("options", single(o_options), optional, "Its options")',
      ]
    end

    it "writes a candidate verb that a rule set aside as its comment alone" do
      expect(statement(TerraformGenerator::Dropped.new("patchThingConfig", [[:merge_subroute, "patchThingConfig"]]))).to eq ["// merge_subroute@patchThingConfig"]
    end
  end

  describe ".file" do
    it "registers the type from init, under a header whose stamp is the start of the SHA-256 of the body below it" do
      type = TerraformGenerator::Type.new(name: "thing", item: "/project/{project_id}/thing/{id}", doc: "A thing", statements: [attr("id")], examples: {}, example_inputs: [], references: {},
        why: [[:type_name, "getThing"], [:doc, "Thing"]])
      path, text = described_class.file(type)
      body = text.lines.drop(1).join
      expect([path, text]).to eq ["internal/provider/thing_gen.go", <<~GO]
        // rake terraform:generate; rake terraform:diff; sha256:#{Digest::SHA256.hexdigest(body)[0, 16]}

        package provider

        func init() {
        \t// type_name@getThing doc@Thing
        \tt := newType("thing", "/project/{project_id}/thing/{id}", "A thing")
        \t// computed@Thing.id
        \tt.attr("id", str, computed, "Its id")
        \tregister(t)
        }
      GO
    end
  end
end
