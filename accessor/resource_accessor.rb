# frozen_string_literal: true

class ResourceAccessor
  @@dynamic_functions = {}

  def self.define_dynamic_function(name, &block)
    @@dynamic_functions[name] = {block: block}
  end

  def self.execute_dynamic_function(name, *args)
    if @@dynamic_functions.key?(name)
      function_info = @@dynamic_functions[name]
      function_info[:block].call(*args[0])
    else
      raise "Dynamic function '#{name}' not found. Make sure it is created firt on remote locations"
    end
  end
end
