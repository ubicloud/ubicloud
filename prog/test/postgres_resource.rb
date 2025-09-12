# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::PostgresResource < Prog::Test::Base
  semaphore :destroy

  def self.assemble
    postgres_test_project = Project.create(name: "Postgres-Test-Project")
    postgres_service_project = Project[Config.postgres_service_project_id] ||
      Project.create_with_id(Config.postgres_service_project_id, name: "Postgres-Service-Project")

    frame = {
      "postgres_service_project_id" => postgres_service_project.id,
      "postgres_test_project_id" => postgres_test_project.id
    }

    Strand.create(
      prog: "Test::PostgresResource",
      label: "start",
      stack: [frame]
    )
  end

  label def start
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id: Location::HETZNER_FSN1_ID,
      name: "postgres-test-standard",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      desired_version: "16"
    )

    update_stack({"postgres_resource_id" => st.id})
    hop_wait_postgres_resource
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
    postgres_resource.incr_destroy
    hop_destroy
  end

  label def destroy
    postgres_test_project.destroy

    fail_test(frame["fail_message"]) if frame["fail_message"]

    pop "Postgres tests are finished!"
  end

  label def failed
    nap 15
  end

  def postgres_test_project
    @postgres_test_project ||= Project[frame["postgres_test_project_id"]]
  end

  def postgres_resource
    @postgres_resource ||= PostgresResource[frame["postgres_resource_id"]]
  end

  def representative_server
    @representative_server ||= postgres_resource.representative_server
  end

  def test_queries_sql
    File.read("./prog/test/testdata/order_analytics_queries.sql")
  end
end
