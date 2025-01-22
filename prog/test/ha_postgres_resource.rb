# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::HaPostgresResource < Prog::Test::Base
  semaphore :destroy

  def self.assemble
    postgres_test_project = Project.create(name: "Postgres-Test-Project")
    postgres_service_project = Project[Config.postgres_service_project_id] ||
      Project.create(name: "Postgres-Service-Project") { _1.id = Config.postgres_service_project_id }
    minio_service_project = Project[Config.minio_service_project_id] ||
      Project.create(name: "MinioServiceProject") { _1.id = Config.minio_service_project_id }

    frame = {
      "postgres_service_project_id" => postgres_service_project.id,
      "postgres_test_project_id" => postgres_test_project.id,
      "minio_service_project_id" => minio_service_project.id
    }

    Strand.create_with_id(
      prog: "Test::HaPostgresResource",
      label: "start",
      stack: [frame]
    )
  end

  label def start
    st = Prog::Minio::MinioClusterNexus.assemble(postgres_service_project.id,
      "minio-0", "hetzner-fsn1", "admin", 256, 1, 1, 1, "standard-2")

    update_stack({"minio_cluster_id" => st.id})
    hop_wait_minio_cluster
  end

  label def wait_minio_cluster
    if minio_cluster.strand.label == "wait"
      hop_create_postgres_resource
    else
      nap 10
    end
  end

  label def create_postgres_resource
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location: "hetzner-fsn1",
      name: "postgres-test-ha",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      ha_type: "async"
    )

    update_stack({"postgres_resource_id" => st.id})
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    num_servers = postgres_resource.servers.count
    required_servers = 1 + postgres_resource.required_standby_count
    nap 10 if num_servers != required_servers || postgres_resource.servers.filter { _1.strand.label != "wait" }.any?
    hop_test_postgres
  end

  label def test_postgres
    unless postgres_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries"})
      hop_destroy_postgres
    end

    hop_trigger_failover
  end

  label def trigger_failover
    primary = postgres_resource.servers.find { _1.timeline_access == "push" }
    update_stack({"primary_ubid" => primary.ubid})

    primary.vm.sshable.cmd("echo -e '\nfoobar' | sudo tee -a /etc/postgresql/#{postgres_resource.version}/main/conf.d/001-service.conf")

    # Get postgres pid and send SIGKILL
    primary.vm.sshable.cmd("ps aux | grep -v grep | grep '/usr/lib/postgresql/#{postgres_resource.version}/bin/postgres' | awk '{print $2}' | xargs sudo kill -9")

    hop_wait_failover
  end

  label def wait_failover
    nap 10 unless postgres_resource.servers.find { _1.timeline_access == "push" }.ubid != frame["primary_ubid"]

    hop_test_postgres_after_failover
  end

  label def test_postgres_after_failover
    unless postgres_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries after failover"})
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

  def postgres_service_project
    @postgres_service_project ||= Project[frame["postgres_service_project_id"]]
  end

  def postgres_resource
    @postgres_resource ||= PostgresResource[frame["postgres_resource_id"]]
  end

  def postgres_server
    @postgres_server ||= postgres_resource.representative_server
  end

  def minio_cluster
    @minio_cluster ||= MinioCluster[frame["minio_cluster_id"]]
  end

  def test_queries_sql
    File.read("./prog/test/testdata/order_analytics_queries.sql")
  end
end
