# frozen_string_literal: true

class Prog::Postgres::TeardownLogAggregation < Prog::Base
  frame_reader :ubid

  def self.assemble(ubid)
    Strand.create(prog: "Postgres::TeardownLogAggregation", label: "start", stack: [{"ubid" => ubid}])
  end

  # The PostgresResource is already gone by the time this runs, so the ubid it
  # named its stream, user and role with is carried in the frame.
  label def start
    register_deadline(nil, 60 * 60, page: "warning")
    hop_teardown
  end

  label def teardown
    if (client = ParseableResource.client_for_project(Config.postgres_service_project_id))
      client.delete_stream(stream_name: ubid)
      client.delete_user(user_id: ubid)
      client.delete_role(role_name: ubid)
    end

    pop "log aggregation teardown is complete"
  end
end
