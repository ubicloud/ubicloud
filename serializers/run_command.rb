# frozen_string_literal: true

class Serializers::RunCommand < Serializers::Base
  # Shape returned when no run has been requested yet.
  NONE = {id: nil, status: nil, output: nil, created_at: nil, run_at: nil}.freeze

  def self.serialize_internal(run_command, options = {})
    {
      id: run_command.ubid,
      status: run_command.status,
      output: run_command.output,
      created_at: run_command.created_at.utc.iso8601,
      run_at: run_command.run_at&.utc&.iso8601,
    }
  end
end
