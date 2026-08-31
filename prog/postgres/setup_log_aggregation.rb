# frozen_string_literal: true

class Prog::Postgres::SetupLogAggregation < Prog::Base
  subject_is :postgres_resource

  def self.assemble(postgres_resource_id)
    Strand.create(prog: "Postgres::SetupLogAggregation", label: "start", stack: [{"subject_id" => postgres_resource_id}])
  end

  # Nothing increments a semaphore on an independent strand to stop it, and
  # destroying (unlike destroy) stays set for the rest of the destroy flow, so
  # a late success cannot recreate what #wait_children_destroyed already removed.
  def before_run
    pop "postgres resource is gone" if postgres_resource.nil? || postgres_resource.destroying_set?
  end

  # Registering the deadline in its own label persists it before #setup gets a
  # chance to fail, as a failing label rolls back its own stack changes.
  label def start
    register_deadline(nil, 60 * 60, page: "warning")
    hop_setup
  end

  label def setup
    postgres_resource.setup_log_aggregation
    postgres_resource.server_incr("configure_logs") if postgres_resource.parseable_password

    pop "log aggregation setup is complete"
  end
end
