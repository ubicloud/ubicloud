# frozen_string_literal: true

class Prog::Test::UnarchivePostgresResource < Prog::Test::PostgresBase
  semaphore :pause, :destroy
  frame_accessor :original_resource_id, :original_timeline_id, :backup_deadline

  def self.assemble(provider: "metal", **)
    super(provider:, project_name: "Postgres-Unarchive-Test-Project", **)
  end

  label def start
    super(name: "postgres-test-unarchive")
  end

  label def wait_postgres_resource
    nap 10 unless postgres_resource.strand.label == "wait" && representative_server.run_query("SELECT 1") == "1"

    if representative_server.run_query(test_queries_sql) != "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      self.fail_message = "Failed to seed test data"
      hop_destroy
    end

    hop_take_backup
  end

  label def take_backup
    self.original_resource_id = postgres_resource.id
    self.original_timeline_id = representative_server.timeline_id
    self.backup_deadline = Time.now.to_i + 15 * 60
    original_timeline.incr_take_backup_for_converge
    hop_wait_backup
  end

  label def wait_backup
    if original_timeline.backups.any?
      # Force WAL rotation so writes after the basebackup get archived;
      # recovery.signal replays to end of archived WAL, so the seeded data
      # must leave the live tail segment before the resource is destroyed.
      representative_server.run_query("SELECT pg_switch_wal()")
      hop_wait_wal_archive
    end

    if Time.now.to_i >= backup_deadline
      self.fail_message = "Backup did not complete in time"
      hop_destroy
    end

    nap 30
  end

  label def wait_wal_archive
    nap 10 unless PostgresTimeline.any_archived_wal?(original_timeline)

    # Destroy only the resource; the retained timeline is what unarchive
    # restores from.
    postgres_resource.incr_destroy
    hop_wait_original_destroyed
  end

  label def wait_original_destroyed
    nap 10 if PostgresResource[original_resource_id]
    hop_unarchive
  end

  label def unarchive
    st = Prog::Postgres::PostgresResourceNexus.unarchive(original_resource_id)
    self.postgres_resource_id = st.id
    self.private_subnet_id = st.subject.private_subnet_id
    hop_wait_unarchived
  end

  label def wait_unarchived
    nap 10 unless postgres_resource.strand.label == "wait" && representative_server.run_query("SELECT 1") == "1"

    if representative_server.run_query(read_queries_sql) != "4159.90\n415.99\n4.1"
      self.fail_message = "Data missing after unarchive"
    end

    hop_destroy
  end

  label def destroy_postgres
    current_timeline_ids = postgres_resource ? postgres_resource.servers_dataset.distinct.select_map(:timeline_id) : []
    self.timeline_ids = ([original_timeline_id] + current_timeline_ids).compact.uniq
    super
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    nap_if_gcp_vpc
    nap_if_private_subnet
    verify_timelines_destroyed(timeline_ids)

    hop_finish
  end

  label :finish
  label :failed
  label :destroy

  def original_timeline
    @original_timeline ||= PostgresTimeline[original_timeline_id]
  end
end
