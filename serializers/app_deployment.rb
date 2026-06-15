# frozen_string_literal: true

class Serializers::AppDeployment < Serializers::Base
  def self.serialize_internal(deployment, options = {})
    {
      id: deployment.ubid,
      version: deployment.version,
      commit_sha: deployment.commit_sha,
      status: deployment.status,
    }
  end
end
