# frozen_string_literal: true

class Serializers::AppResource < Serializers::Base
  def self.serialize_internal(app_resource, options = {})
    h = {
      id: app_resource.ubid,
      name: app_resource.name,
      repo_url: app_resource.repo_url,
      branch: app_resource.branch,
      state: app_resource.display_state,
      hostname: app_resource.hostname,
    }

    if options[:detailed]
      h[:processes] = Serializers::AppProcess.serialize(app_resource.processes)
      h[:deployments] = Serializers::AppDeployment.serialize(app_resource.deployments)
    end

    h
  end
end
