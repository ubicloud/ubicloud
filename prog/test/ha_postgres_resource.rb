# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::HaPostgresResource < Prog::Test::Base
  def self.assemble
    postgres_test_project = Project.create(name: "Postgres-HA-Test-Project")

    frame = {
      "postgres_test_project_id" => postgres_test_project.id,
      "failover_wait_started" => false
    }

    Strand.create(
      prog: "Test::HaPostgresResource",
      label: "start",
      stack: [frame]
    )
  end

  label def start
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id: Location::HETZNER_FSN1_ID,
      name: "postgres-test-ha",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      ha_type: "async"
    )

    update_stack({"postgres_resource_id" => st.id})
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    server_count = postgres_resource.servers.count
    nap 10 if server_count != postgres_resource.target_server_count || postgres_resource.servers.filter { it.strand.label != "wait" }.any?
    hop_test_postgres
  end

  label def test_postgres
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries"})
      hop_destroy_postgres
    end

    hop_trigger_failover
  end

  label def trigger_failover
    Clog.emit("Postgres servers before failover: #{postgres_resource.servers.map { |s| "[#{s.ubid}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")
    primary = postgres_resource.servers.find { it.timeline_access == "push" }
    update_stack({"primary_ubid" => primary.ubid})
    version = postgres_resource.version

    primary.vm.sshable.cmd("echo -e '\nfoobar' | sudo tee -a /etc/postgresql/:version/main/conf.d/001-service.conf", version:)

    # Get postgres pid and send SIGKILL
    primary.vm.sshable.cmd("ps aux | grep -v grep | grep '/usr/lib/postgresql/:version/bin/postgres' | awk '{print $2}' | xargs sudo kill -9", version:)

    hop_wait_failover
  end

  label def wait_failover
    # Wait 3 minutes for the failover to finish.
    failover_wait_started = frame["failover_wait_started"]
    update_stack({"failover_wait_started" => true})

    nap 180 unless failover_wait_started

    hop_test_postgres_after_failover
  end

  label def test_postgres_after_failover
    Clog.emit("Postgres servers after failover: #{postgres_resource.servers.map { |s| "[#{s.ubid}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")

    new_candidate = postgres_resource.servers.filter { |s| s.ubid != frame["primary_ubid"] }.min_by(&:created_at)
    if new_candidate
      # Get last few log lines from the new candidate for debugging.
      log_lines = new_candidate.vm.sshable.cmd("sudo tail -n 20 /dat/:version/data/pg_log/postgresql.log", version: new_candidate.version)
      Clog.emit("Last log lines from new candidate (#{new_candidate.ubid}):\n#{log_lines}")
    else
      Clog.emit("No new primary found after failover")
    end

    Clog.emit("Running read queries after failover")
    unless representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries after failover"})
      hop_destroy_postgres
    end

    Clog.emit("Running write queries after failover")
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run write queries after failover"})
    end

    hop_destroy_postgres
  end

  label def destroy_postgres
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    hop_finish
  end

  label def finish
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
    File.read("./prog/test/testdata/order_analytics_queries.sql").freeze
  end

  def read_queries_sql
    File.read("./prog/test/testdata/order_analytics_read_queries.sql").freeze
  end
end
