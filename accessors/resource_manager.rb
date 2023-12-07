# frozen_string_literal: true

class ResourceManager
  @@remote_resource_accessor = {}

  def self.add_remote(location_name, there)
    @@remote_resource_accessor[location_name] = there
  end

  def self.get_all(project, current_user, resource_type)
    # TODOBV: Either dynamically generate or have a map. So bad rn
    # just tried some dynamic calls to play with it
    func_to_call = if resource_type == "vm"
      :project_vm_get
    else
      :project_private_subnet_get
    end

    local_resources = ResourceAccessor.send(func_to_call, project, current_user)

    remote_resources = []
    @@remote_resource_accessor.each do |_, remote_accessor|
      remote_resources += remote_accessor.send(func_to_call, project, current_user)
    end

    local_resources + remote_resources
  end

  def self.post(location, project, params, resource_type)
    func_to_call = if resource_type == "vm"
      :project_vm_post
    else
      :project_private_subnet_post
    end

    if location == "local" # TODOBV: From the config, no-op but info
      ResourceAccessor.send(func_to_call, project, params)
    else
      @@remote_resource_accessor[location].send(func_to_call, project, params)
    end
  end

  # TODOBV: Add get for location based single resources
  # TODOBV: Add func for semaphores (should I ?)

  # postgres
  # minio
  # ...
end
