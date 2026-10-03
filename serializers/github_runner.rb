# frozen_string_literal: true

class Serializers::GithubRunner < Serializers::Base
  def self.serialize_internal(runner, options = {})
    {
      id: runner.ubid,
      repository_name: runner.repository_name,
      label: runner.label,
      vcpus: runner.label_data["vcpus"],
      arch: runner.label_data["arch"],
      status: runner.status,
      created_at: runner.created_at.utc.iso8601,
    }
  end
end
