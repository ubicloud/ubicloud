# frozen_string_literal: true

class ResourceManager
  @@remote_resource_accessor = {}

  def self.add_remote(location_name, there)
    @@remote_resource_accessor[location_name] = there
  end

  def self.get_all(project, current_user, resource_type)
    local_resources = ResourceAccessor.get_all(project, current_user, resource_type)

    remote_resources = []
    @@remote_resource_accessor.each do |_, remote_accessor|
      remote_resources += remote_accessor.get_all(project, current_user, resource_type)
    end

    local_resources + remote_resources
  end

  # TODOBV: What if get returns DRb object reference?
  def self.get(location, project, name, resource_type)
    if location == "local"
      ResourceAccessor.get(project, name, resource_type)
    else
      @@remote_resource_accessor[location].get(project, name, resource_type)
    end
  end

  def self.post(location, project, params, resource_type)
    if location == "local"
      ResourceAccessor.post(project, params, resource_type)
    else
      @@remote_resource_accessor[location].post(project, params, resource_type)
    end
  end

  def self.delete(location, resource, resource_type)
    if location == "local"
      ResourceAccessor.delete(resource, resource_type)
    else
      @@remote_resource_accessor[location].delete(resource, resource_type)
    end
  end

  # def run --> give block? security ? 

  # TODOBV: Add func for semaphores (should I ?)

  # postgres
  # minio
  # ...
end
