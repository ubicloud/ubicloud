# frozen_string_literal: true

class OptionTreeGenerator
  def initialize
    @options = []
    @parents = {}
  end

  def add_option(name:, values: nil, parent: nil, &check)
    @options << {name:, values:, parent:, check:}
  end

  def build_subtree(option, path)
    return unless option[:values]

    subtree = {}
    Array(option[:values]).each do |value|
      next if option[:check] && !option[:check].call(*path, value)

      child_options = @options.select { |opt| opt[:parent] == option[:name] }
      subtree[value] = child_options.to_h do |child_option|
        @parents[child_option[:name]] = @parents[option[:name]] + [option[:name]]
        [child_option[:name], build_subtree(child_option, path + [value])]
      end
    end

    subtree
  end

  def serialize
    option_tree = {}
    @options.each do |option|
      if option[:parent].nil?
        @parents[option[:name]] = []
        option_tree[option[:name]] = build_subtree(option, [])
      end
    end

    [option_tree, @parents]
  end

  def self.generate_allowed_options(name, option_tree, parents)
    allowed_options = []

    traverse = lambda do |tree, path_to_follow, current_path|
      if path_to_follow.empty?
        allowed_options << current_path
      else
        current_node = path_to_follow.first
        tree[current_node].keys.each do |option|
          new_path = current_path.dup
          new_path[path_to_follow.first] = option
          traverse.call(tree[path_to_follow.first][option], path_to_follow[1..], new_path)
        end
      end
    end

    traverse.call(option_tree, parents[name] + [name], {})

    allowed_options
  end

  def self.collect_valid_values(option_tree)
    result = Hash.new { |h, k| h[k] = Set.new }
    walk = lambda do |tree|
      tree.each do |name, subtree|
        next unless subtree
        subtree.each do |value, children|
          result[name] << value
          walk.call(children)
        end
      end
    end
    walk.call(option_tree)
    result
  end

  def self.stringify_tree(option_tree)
    option_tree.each_with_object({}) do |(key, value), result|
      next if value.nil?
      serialized_key = key.is_a?(Location) ? key.name : key.to_s
      result[serialized_key] = stringify_tree(value)
    end
  end
end
