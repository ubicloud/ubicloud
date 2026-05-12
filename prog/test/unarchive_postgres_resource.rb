# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::UnarchivePostgresResource < Prog::Test::PostgresBase
  def self.assemble(provider: "metal")
    postgres_test_project = Project.create(name: "Postgres-Unarchive-Test-Project")
    Project[Config.postgres_service_project_id] ||
      Project.create_with_id(Config.postgres_service_project_id || Project.generate_uuid, name: "Postgres-Service-Project")

    Strand.create(
      prog: "Test::UnarchivePostgresResource",
      label: "start",
      stack: [{"postgres_test_project_id" => postgres_test_project.id, "provider" => provider}],
    )
  end

  label def start
    location_id, target_vm_size, target_storage_size_gib = self.class.postgres_test_location_options(frame["provider"])

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      name: "postgres-test-unarchive",
      target_vm_size:,
      target_storage_size_gib:,
    )

    update_stack({"postgres_resource_id" => st.id})
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    nap 10 unless postgres_resource.strand.label == "wait" && representative_server.run_query("SELECT 1") == "1"

    if representative_server.run_query(test_queries_sql) != "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to seed test data"})
      hop_destroy_postgres
    end

    hop_take_backup
  end

  label def take_backup
    d_command = NetSsh.command("sudo postgres/bin/take-backup :version", version: representative_server.version)
    representative_server.vm.sshable.cmd("common/bin/daemonizer :d_command take_postgres_backup", d_command:)
    update_stack({
      "original_resource_id" => postgres_resource.id,
      "timeline_id" => postgres_resource.timeline.id,
      "backup_deadline" => Time.now.to_i + 600,
    })
    hop_wait_backup
  end

  label def wait_backup
    case representative_server.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup").strip
    when "Succeeded"
      # Force WAL rotation so writes after the basebackup get archived too;
      # otherwise the tail segment with our test data sits in pg_wal until
      # destroy and unarchive's recovery_target_lsn would land before it.
      representative_server.run_query("SELECT pg_switch_wal()")
      hop_wait_wal_archive
    when "Failed"
      update_stack({"fail_message" => "Backup failed"})
      hop_destroy_postgres
    else
      if Time.now.to_i >= frame["backup_deadline"]
        update_stack({"fail_message" => "Backup did not complete in time"})
        hop_destroy_postgres
      end
      nap 30
    end
  end

  label def wait_wal_archive
    if PostgresTimeline.latest_archived_wal_lsn(postgres_resource.timeline)
      hop_destroy_resource_only
    else
      nap 10
    end
  end

  label def destroy_resource_only
    # Cascades servers via destroy_vm_and_pg, leaving timeline intact so
    # unarchive can find it.
    postgres_resource.incr_destroy
    hop_wait_resource_destroyed
  end

  label def wait_resource_destroyed
    nap 10 if PostgresResource[frame["original_resource_id"]]
    hop_unarchive
  end

  label def unarchive
    st = Prog::Postgres::PostgresResourceNexus.unarchive(frame["original_resource_id"])
    update_stack({"postgres_resource_id" => st.id})
    hop_wait_unarchived
  end

  label def wait_unarchived
    nap 10 unless postgres_resource&.strand&.label == "wait" && representative_server.run_query("SELECT 1") == "1"

    if representative_server.run_query(read_queries_sql) != "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Data missing after unarchive"})
    end

    hop_destroy_postgres
  end

  label def destroy_postgres
    if (timeline = PostgresTimeline[frame["timeline_id"]])
      timeline.incr_destroy
    end
    postgres_resource&.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    if PrivateSubnet[project_id: frame["postgres_test_project_id"]]
      Clog.emit("Waiting for private subnet to be destroyed")
      nap 5
    end

    hop_finish
  end

  label def finish
    if (fail_message = frame["fail_message"])
      fail_test(fail_message)
    end
    pop "Postgres unarchive tests are finished!"
  end

  label def failed
    nap 15
  end
end
