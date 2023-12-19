# frozen_string_literal: true

# TODO: Add error handling here. Send errors together with results to the caller.
# Though that mean callers need to handle errors separately.
class ResourceManager
  @@remote_resource_accessor = {}

  def self.add_remote(location_name, there)
    @@remote_resource_accessor[location_name] = there
  end

  def self.run_on_all_locations(func_name, *args)
    results = []

    local_return_value = ResourceAccessor.execute_dynamic_function(func_name, args)
    results += local_return_value

    # TODO: Send those request in parallel
    @@remote_resource_accessor.each do |_, remote_accessor|
      remote_return_value = remote_accessor.execute_dynamic_function(func_name, args)
      results += remote_return_value
    end

    results
  end

  def self.run_on_location(func_name, location, *args)
    (location == Config.location_name) ? ResourceAccessor.execute_dynamic_function(func_name, args) : @@remote_resource_accessor[location].execute_dynamic_function(func_name, args)
  end
end
