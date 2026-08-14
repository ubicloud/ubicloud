# frozen_string_literal: true

class Serializers::RunCommand < Serializers::Base
  def self.serialize_internal(run_command, options = {})
    {
      status: run_command.status,
      output: run_command.output,
      timestamp: (run_command.run_at || run_command.created_at).utc.iso8601,
    }
  end
end
