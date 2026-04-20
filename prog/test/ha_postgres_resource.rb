# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::HaPostgresResource < Prog::Test::PostgresBase
  def self.assemble(provider: "metal")
    postgres_test_project = Project.create(name: "Postgres-HA-Test-Project")
    Project[Config.postgres_service_project_id] ||
      Project.create_with_id(Config.postgres_service_project_id || Project.generate_uuid, name: "Postgres-Service-Project")

    Strand.create(
      prog: "Test::HaPostgresResource",
      label: "start",
      stack: [{"postgres_test_project_id" => postgres_test_project.id, "provider" => provider}],
    )
  end

  label def start
    location_id, target_vm_size, target_storage_size_gib = self.class.postgres_test_location_options(frame["provider"])

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      name: "postgres-test-ha",
      target_vm_size:,
      target_storage_size_gib:,
      ha_type: "async",
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

    primary.vm.sshable.cmd("echo -e '\nfoobar = baz' | sudo tee -a /etc/postgresql/:version/main/conf.d/999-break.conf", version:)

    # Get postgres pid and send SIGKILL
    primary.vm.sshable.cmd("ps aux | grep -v grep | grep /usr/lib/postgresql/:version/bin/postgres | awk '{print $2}' | xargs sudo kill -9", version:)

    hop_wait_failover
  end

  label def wait_failover
    deadline = frame["failover_deadline"]
    unless deadline
      deadline = Time.now.to_i + 600
      update_stack({"failover_deadline" => deadline})
    end

    new_primary = postgres_resource.servers(eager: :strand).find { |s| s.ubid != frame["primary_ubid"] && s.timeline_access == "push" && s.strand.label == "wait" }
    hop_test_postgres_after_failover if new_primary

    if Time.now.to_i >= deadline
      update_stack({"fail_message" => "Failover did not complete within 600 seconds"})
      hop_destroy_postgres
    end

    nap 10
  end

  label def test_postgres_after_failover
    Clog.emit("Postgres servers after failover: #{postgres_resource.servers.map { |s| "[#{s.ubid}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")

    new_candidate = postgres_resource.servers.filter { |s| s.ubid != frame["primary_ubid"] }.min_by(&:created_at)
    # Get last few log lines from the new candidate for debugging.
    log_lines = new_candidate.vm.sshable.cmd("sudo find /dat/:version/data/pg_log/ -name 'postgresql-*.log' -exec tail -n 20 {} \\;", version: new_candidate.version)
    Clog.emit("Last log lines from new candidate (#{new_candidate.ubid}):\n#{log_lines}")

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
    postgres_resource.timeline.incr_destroy
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    hop_finish
  end

  label def finish
    finish_test("Postgres tests are finished!")
  end

  label def failed
    nap 15
  end
end
