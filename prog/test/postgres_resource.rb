# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::PostgresResource < Prog::Test::PostgresBase
  def self.assemble(provider: "metal")
    super(provider:, project_name: "Postgres-Test-Project")
  end

  label def start
    super(name: "postgres-test-standard")
  end

  label def wait_postgres_resource
    if postgres_resource.strand.label == "wait" &&
        representative_server.run_query("SELECT 1") == "1"
      hop_test_postgres
    else
      nap 10
    end
  end

  label def test_postgres
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries"})
    end

    hop_destroy_postgres
  end

  label def destroy_postgres
    postgres_resource.timeline.incr_destroy
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    nap_if_private_subnet
    hop_finish
  end

  label :finish
  label :failed
end
