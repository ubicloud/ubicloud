# frozen_string_literal: true

class ResourceAccessor
  def self.accessor_for(resource_type)
    case resource_type
    when "vm"
      VmAccessor
    when "private_subnet"
      PrivateSubnetAccessor
    else
      raise ArgumentError, "Unsupported resource type: #{resource_type}, add accessor for it"
    end
  end
  class << self
    def method_missing(method_name, *args, &block)
      allowed_functions = ["get", "get_all", "post", "delete"]
      if !allowed_functions.include? method_name.to_s
        puts "ResourceAccessor supports only #{allowed_functions.join(",")} functions"
      else
        accessor_for(args.last).send(method_name, *args[0..-2], &block)
      end
    end

    def respond_to_missing?(method_name, _include_private = false)
      true
    end
  end
end

# Following are assumed to be exist globally
# current_user
# project
# project_data (sec)
# project_permissions (sec)
# policy

# prices --> can be different (not a problem)
