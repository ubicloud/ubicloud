# frozen_string_literal: true

RSpec.describe TerraformGenerator::Hcl do
  # A type with an attribute for each example, each required except id,
  # and its example sets them. It is a resource, or only a datasource if it
  # is given a lookup.
  def type(name, item, examples, references: {}, lookup: nil)
    attrs = examples.keys.map { TerraformGenerator::Attr.new(name: it, type: :str, flags: Set[(it == "id") ? :computed : :required], doc: "", default: nil, checks: [], why: []) }
    statements = [lookup ? TerraformGenerator::Datasource.new(lookup, []) : TerraformGenerator::Create.new("POST", item, [], []), *attrs]
    TerraformGenerator::Type.new(name:, item:, doc: "", statements:, examples:, example_inputs: examples.keys - ["id"], references:, why: [])
  end

  # The files, each without its header.
  def files(*types) = described_class.files(types).to_h.transform_values { it.lines.drop(1).join }

  it "writes a resource's example inputs, aligned, and imports it by its item path's attributes" do
    thing = type("thing", "/project/{project_id}/location/{location}/thing/{id}", {"id" => "th1", "location" => "eu central", "name" => "my-thing", "size" => 2})
    expect(files(thing)).to eq(
      "examples/resources/ubicloud_thing/resource.tf" => <<~HCL,

        resource "ubicloud_thing" "example" {
          location = "eu central"
          name     = "my-thing"
          size     = 2
        }
      HCL
      "examples/resources/ubicloud_thing/import.sh" => "\nterraform import ubicloud_thing.example eu\\ central/th1\n",
    )
    expect(described_class.files([thing]).map { it.last.lines.first }).to all(match(/\A# #{TerraformGenerator::HEADER}; sha256:\h{16}\n\z/o))
  end

  it "writes an empty block for a resource whose example sets no input" do
    expect(files(type("thing", "/project/{project_id}/thing/{id}", {"id" => "th1"}))["examples/resources/ubicloud_thing/resource.tf"])
      .to eq %(\nresource "ubicloud_thing" "example" {}\n)
  end

  it "refers an attribute that holds another type's id to that type's example, which comes first, once" do
    a = type("a", "/project/{project_id}/a/{id}", {"id" => "a1", "name" => "my-a"})
    b = type("a_b", "/project/{project_id}/a/{a_id}/b/{id}", {"a_id" => "a1", "id" => "b1"}, references: {"a_id" => "a"})
    c = type("a_b_c", "/project/{project_id}/a/{a_id}/b/{a_b_id}/c/{id}", {"a_b_id" => "b1", "a_id" => "a1", "id" => "c1"}, references: {"a_b_id" => "a_b", "a_id" => "a"})
    expect(files(a, b, c).values_at("examples/resources/ubicloud_a_b_c/resource.tf", "examples/resources/ubicloud_a_b_c/import.sh")).to eq [<<~HCL, "\nterraform import ubicloud_a_b_c.example a1/b1/c1\n"]

      resource "ubicloud_a" "example" {
        name = "my-a"
      }

      resource "ubicloud_a_b" "example" {
        a_id = ubicloud_a.example.id
      }

      resource "ubicloud_a_b_c" "example" {
        a_b_id = ubicloud_a_b.example.id
        a_id   = ubicloud_a.example.id
      }
    HCL
  end

  it "refuses an example that refers to a type no definition offers as a resource" do
    b = type("a_b", "/project/{project_id}/a/{a_id}/b/{id}", {"a_id" => "a1", "id" => "b1"}, references: {"a_id" => "a"})
    [[b], [b, type("a", "/project/{project_id}/a/{id}", {"id" => "a1"}, lookup: %w[id])]].each do |types|
      expect { described_class.files(types) }
        .to raise_error(TerraformGenerator::SpecError, "definitions a_b: its example refers to a, which no definition offers as a resource; define it")
    end
  end

  it "refers a resource's datasource example to the resource's example" do
    thing = type("thing", "/project/{project_id}/location/{location}/thing/{id}", {"id" => "th1", "location" => "eu-central-h1"})
    thing = thing.with(statements: [TerraformGenerator::Datasource.new(%w[id], []), *thing.statements])
    expect(files(thing)["examples/data-sources/ubicloud_thing/data-source.tf"]).to eq <<~HCL

      data "ubicloud_thing" "example" {
        id       = ubicloud_thing.example.id
        location = ubicloud_thing.example.location
      }
    HCL
  end

  it "looks a datasource's object up by its keys and name, else by id, and the scope's by nothing" do
    named = type("thing", "/project/{project_id}/location/{location}/thing/{id}", {"id" => "th1", "location" => "eu-central-h1", "name" => "my-thing"}, lookup: %w[id name])
    unnamed = type("other", "/project/{project_id}/other/{id}", {"id" => "ot1"}, lookup: %w[id name])
    scope = type("scope", "/project/{project_id}", {"id" => "pj1"}, lookup: [])
    expect(files(named, unnamed, scope)).to eq(
      "examples/data-sources/ubicloud_thing/data-source.tf" => <<~HCL,

        data "ubicloud_thing" "example" {
          location = "eu-central-h1"
          name     = "my-thing"
        }
      HCL
      "examples/data-sources/ubicloud_other/data-source.tf" => %(\ndata "ubicloud_other" "example" {\n  id = "ot1"\n}\n),
      "examples/data-sources/ubicloud_scope/data-source.tf" => %(\ndata "ubicloud_scope" "example" {}\n),
    )
  end

  describe ".literal" do
    it "writes a string as HCL, escaping what HCL would read as an escape or a template" do
      expect([%(say "hi"), "a\\b", "line\nbreak\ttab", "café ☃", "${var} %{if} $${kept}"].map { described_class.literal(it) })
        .to eq [%("say \\"hi\\""), %("a\\\\b"), %("line\\nbreak\\ttab"), %("café ☃"), %("$${var} %%{if} $$${kept}")]
    end

    it "writes numbers, booleans, lists and objects" do
      expect([2, 1.5, true, false, ["a", 1], [], {"k" => "v", 1 => [true]}, {}].map { described_class.literal(it) })
        .to eq ["2", "1.5", "true", "false", %(["a", 1]), "[]", %({ "k" = "v", "1" = [true] }), "{}"]
    end

    it "refuses a value it has no form for" do
      expect { described_class.literal(:symbol) }.to raise_error(NoMatchingPatternError)
    end
  end
end
