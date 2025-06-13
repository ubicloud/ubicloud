# frozen_string_literal: true

class OptionTreeGenerator
  def initialize
    @options = []
    @parents = {}
  end

  def add_option(name:, values: nil, parent: nil, check: nil)
    @options << {name:, values:, parent:, check:}
  end

  def build_subtree(option, path)
    return unless option[:values]

    subtree = {}
    Array(option[:values]).each do |value|
      next if option[:check] && !option[:check].call(*path, value)
      child_options = @options.select { |opt| opt[:parent] == option[:name] }
      subtree[value] = child_options.map do |child_option|
        @parents[child_option[:name]] = @parents[option[:name]] + [option[:name]]
        [child_option[:name], build_subtree(child_option, path + [value])]
      end.to_h
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
end
