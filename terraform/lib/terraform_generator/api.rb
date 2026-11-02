# frozen_string_literal: true

require "yaml"

# Api holds the OpenAPI spec in the form that the derivation reads. A
# resolved reference keeps its $ref beside the content it names, so that
# the derivation can say which schema a fact came from. A schema keeps
# its allOf members after they are merged into it, because the derivation
# still looks at them.
class TerraformGenerator::Api
  # An item path, and its path parameters in the order they appear in the path.
  Item = Data.define(:path, :params)

  METHODS = %w[get put post delete options head patch trace].freeze

  # The spec's examples include unquoted timestamps, which YAML reads as
  # Time, and x-deprecated gives its dates unquoted, which YAML reads as Date.
  def self.load = new(YAML.load_file(TerraformGenerator::SPEC, permitted_classes: [Time, Date]))

  attr_reader :paths, :scope, :items

  def initialize(doc)
    @doc = doc
    @paths = resolve(doc.fetch("paths")).transform_values { operations(it) }
    item_paths = @paths.filter_map { |path, ops| path if path.end_with?("}") && ops.keys.intersect?(%w[get delete]) }
    @scope = item_paths.min_by(&:length)
    @items = index(item_paths)
    Ractor.make_shareable(self)
  end

  private

  def resolve(node)
    case node
    in Hash if (ref = node["$ref"])
      resolve(@doc.dig(*ref.delete_prefix("#/").split("/"))).merge("$ref" => ref)
    in Hash
      merge_all_of(node.transform_values { resolve(it) })
    in Array
      node.map { resolve(it) }
    else
      node
    end
  end

  def merge_all_of(schema)
    return schema unless (members = schema["allOf"])
    parts = [*members, schema]
    schema.merge(
      "properties" => parts.map { it.fetch("properties", {}) }.reduce(:merge),
      "required" => parts.flat_map { it.fetch("required", []) }.uniq,
    )
  end

  # The operation's parameters take precedence over the path's.
  def operations(path_item)
    shared = path_item.fetch("parameters", [])
    path_item.slice(*METHODS).transform_values do |op|
      op.merge("parameters" => (op.fetch("parameters", []) + shared).uniq { it.values_at("name", "in") })
    end
  end

  def index(item_paths)
    if (outside = item_paths.find { !"#{it}/".start_with?("#{@scope}/") })
      raise TerraformGenerator::SpecError, "item path #{outside} does not begin with #{@scope}, the shortest item path"
    end

    item_paths.group_by { type_name(it) }.to_h do |name, (path, *others)|
      raise TerraformGenerator::SpecError, "#{path} and #{others.join(" and ")} derive the same type name, #{name}" if others.any?
      [name, Item.new(path:, params: params(path))]
    end
  end

  # The nouns are the literal segments just before each parameter, once the
  # scope and any /location/{location} after it are removed. A noun that
  # begins with the previous noun and a hyphen replaces the previous one, so
  # that /a/{a_id}/a-b/{b_id} gives a_b.
  def type_name(path)
    rest = (path == @scope) ? path : path.delete_prefix(@scope).delete_prefix("/location/{location}")
    nouns = rest.scan(%r{([^/{}]+)/\{}).flatten
    nouns.reject.with_index { |noun, i| nouns[i + 1]&.start_with?("#{noun}-") }.join("_").tr("-", "_")
  end

  def params(path)
    ops = @paths[path]
    (ops["get"] || ops["delete"])["parameters"].select { it["in"] == "path" }.sort_by { path.index("{#{it["name"]}}") }
  end
end
