# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::PostgresResource < Prog::Test::Base
  semaphore :destroy

  def self.assemble(provider: "metal")
    postgres_test_project = Project.create(name: "Postgres-Test-Project")
    postgres_service_project = Project[Config.postgres_service_project_id] ||
      Project.create_with_id(Config.postgres_service_project_id || Project.generate_uuid, name: "Postgres-Service-Project")

    frame = {
      "provider" => provider,
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
    location_id, target_vm_size, target_storage_size_gib = if frame["provider"] == "aws"
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationCredential.create_with_id(location.id, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    else
      [Location::HETZNER_FSN1_ID, "standard-2", 128]
    end

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      name: "postgres-test-standard",
      target_vm_size:,
      target_storage_size_gib:
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
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    if PrivateSubnet[project_id: frame["postgres_test_project_id"]]
      Clog.emit("Waiting for private subnet to be destroyed")
      nap 5
    end

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
