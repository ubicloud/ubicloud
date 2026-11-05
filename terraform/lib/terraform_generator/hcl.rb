# frozen_string_literal: true

require "json"
require "shellwords"

# Hcl writes each type's examples, which serve both as the documentation's
# examples and as the harness's fixtures.
module TerraformGenerator::Hcl
  include TerraformGenerator

  def self.files(types)
    resources = types.select { it.statements.any?(Create) }.to_h { [it.name, it] }
    types.flat_map { [*resource(it, resources), *datasource(it, resources)] }
  end

  def self.resource(type, resources)
    return [] unless resources.key?(type.name)
    dir = "examples/resources/#{address(type.name)}"
    blocks = needs(type, resources).map { |t| block("resource", t, t.example_inputs.to_h { [it, value(t, it)] }) }
    import = "terraform import #{address(type.name)}.example #{Shellwords.escape(parts(type).map { type.examples.fetch(it) }.join("/"))}\n"
    [["#{dir}/resource.tf", file(blocks)], ["#{dir}/import.sh", file([import])]]
  end

  # A datasource's example gives the keys, and looks the object up by name
  # where it can, else by id. The values refer to the resource's example,
  # if the type has one, so that the two can be applied together; else
  # they are example values. The scope's datasource takes no argument.
  def self.datasource(type, resources)
    lookup = type.statements.grep(Datasource).first&.lookup or return []
    by = %w[name id].find { lookup.include?(it) && type.examples.key?(it) }
    attrs = [*(parts(type) - ["id"]), *by].sort.to_h { [it, resources.key?(type.name) ? "#{address(type.name)}.example.#{it}" : literal(type.examples.fetch(it))] }
    [["examples/data-sources/#{address(type.name)}/data-source.tf", file([block("data", type, attrs)])]]
  end

  # An attribute that holds another type's id refers to that type's
  # example, which the file includes first.
  def self.needs(type, resources)
    others = type.references.values.map do |name|
      resources.fetch(name) { raise SpecError, "definitions #{type.name}: its example refers to #{name}, which no definition offers as a resource; define it" }
    end
    [*others.flat_map { needs(it, resources) }, type].uniq
  end

  # The import id is made of the attributes in the item path.
  def self.parts(type) = type.item.scan(/\{(\w+)\}/).flatten & type.statements.grep(Attr).map(&:name)

  def self.value(type, name)
    ref = type.references[name]
    ref ? "#{address(ref)}.example.id" : literal(type.examples.fetch(name))
  end

  # terraform fmt aligns the = of consecutive attributes.
  def self.block(kind, type, attrs)
    head = %(#{kind} "#{address(type.name)}" "example" {)
    return "#{head}}\n" if attrs.empty?
    width = attrs.keys.map(&:size).max
    "#{head}\n#{attrs.map { |name, v| "  #{name.ljust(width)} = #{v}\n" }.join}}\n"
  end

  def self.file(blocks) = TerraformGenerator.stamped("#", "\n#{blocks.join("\n")}")

  def self.address(name) = "ubicloud_#{name}"

  # A JSON string is an HCL string, except that HCL reads ${ and %{ as the
  # start of a template; a second $ or % escapes them.
  def self.literal(v)
    case v
    in String then JSON.generate(v).gsub(/([$%])\{/, '\1\1{')
    in Integer | Float | true | false then v.to_s
    in Array then "[#{v.map { literal(it) }.join(", ")}]"
    in Hash then v.empty? ? "{}" : "{ #{v.map { |k, x| "#{literal(k.to_s)} = #{literal(x)}" }.join(", ")} }"
    end
  end
end
