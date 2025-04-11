# frozen_string_literal: true

class OptionTreeGenerator
  class InputOptions
    def initialize(options, option_tree, parents)
      @options = {}
      @dependencies = {}
      @configurations = {}
      @display_data = {}
      options.each { self << _1 }
      @options.each do |name, option|
        option[:options] = OptionTreeGenerator.generate_allowed_options(name, option_tree, parents)
      end
    end

    def <<(option)
      return unless option[:values]
      name = option[:name]
      @options[name] = {options: option[:values]}
      if (parent_name = option[:parent])
        @options[parent_name][:provides] ||= parent_name
        @dependencies[name] = [parent_name, *@dependencies[parent_name]]
      end
    end

    def [](name)
      @options.fetch(name)
    end

    def ignore_dependency(dep)
      @dependencies.each_value do
        _1.delete(dep)
      end
    end

    def configure(name, **opts, &block)
      @configurations[name] = [opts, block]
    end

    def configure_display(name, &block)
      @display_data[name] = block
    end

    def form_options(name)
      opts = self[name].dup
      deps = @dependencies[name]
      config_opts, config_block = @configurations[name]
      config_opts ||= {}
      display_block = @display_data[name]

      opts[:options] = opts[:options].map do |hash|
        val = hash[name]
        if deps
          class_attr = option_classes(name, hash)
        end

        if config_block
          config_block.call(val, hash, class_attr)
        else
          text_method = config_opts[:text_method]
          value_method = config_opts[:value_method]
          text = text_method ? val.send(text_method) : val
          value = value_method ? val.send(value_method) : val
          filter = "#{name}-#{value}"
          attr = {filter:}
          id = "#{filter}-" << deps.map do
            id_val = hash[_1]
            id_val = id_val.id if id_val.is_a?(Location)
            id_val
          end.join("-")
          if class_attr
            class_attr += " selected-#{value}"
          end

          button_options = {value:, attr:, id:, label_attr: {class: class_attr}}
          if display_block
            button_options[:display_data] = display_block.call(hash)
          end

          [text, button_options]
        end
      end
      opts[:dependencies] = deps.join(" ")
      opts
    end

    def option_classes(name, value)
      @dependencies.fetch(name).map do |dependency_name|
        dep_val = value[dependency_name]
        if dep_val.is_a?(Location)
          dep_val = dep_val.id
        end

        "depends-#{dependency_name} #{dependency_name}-#{dep_val}"
      end.join(" ")
    end
  end

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

    [option_tree, @parents, InputOptions.new(@options, option_tree, @parents)]
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
