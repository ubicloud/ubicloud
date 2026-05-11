# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::UpgradePostgresResource < Prog::Test::PostgresBase
  semaphore :pause, :destroy

  def self.assemble(provider: "metal", start_version: "17", **)
    st = super(provider:, project_name: "Postgres-Upgrade-Test-Project", **)
    st.update(stack: [st.stack.first.merge("start_version" => start_version)])
    st
  end

  label def start
    user_config = {}
    # sync_replication_slots is PG17+; PG16 would reject config
    user_config["sync_replication_slots"] = "on" if start_version.to_i >= 17

    super(name: "postgres-test-upgrade-pg#{start_version}", ha_type: "async", target_version: start_version, user_config:) do |resource, frame|
      frame["pre_upgrade_postgres_timeline_id"] = resource.timeline.id
    end
  end

  label def wait_postgres_resource
    servers = postgres_resource.servers
    nap 10 if servers.count != postgres_resource.target_server_count || servers.filter { it.strand.label != "wait" }.any?
    hop_setup_failover_slot
  end

  label def setup_failover_slot
    # PG17+ preserves logical slots across pg_upgrade & adds failover plus sync on standbys
    # PG16 logical slots are dropped by pg_upgrade, still create one to assert upgrade does not hang
    unless (standby = postgres_resource.servers.find { !it.is_representative })
      update_stack({"fail_message" => "No standby found to verify failover slot sync"})
      hop_destroy
    end

    existing = representative_server.run_query("SELECT 1 FROM pg_replication_slots WHERE slot_name = 'upgrade_test_slot'").strip
    if existing.empty?
      Clog.emit("Creating logical replication slot", {failover: start_version.to_i >= 17})
      create_sql = if start_version.to_i >= 17
        "SELECT pg_create_logical_replication_slot('upgrade_test_slot', 'pgoutput', false, false, true)"
      else
        "SELECT pg_create_logical_replication_slot('upgrade_test_slot', 'pgoutput', false, false)"
      end
      representative_server.run_query(create_sql)
    end

    # PG16 does not sync replication slots to standbys; skip the wait.
    hop_test_postgres_before_read_replica if start_version.to_i < 17

    synced = standby.run_query("SELECT 1 FROM pg_replication_slots WHERE slot_name = 'upgrade_test_slot' AND synced AND NOT temporary").strip
    if synced.empty?
      Clog.emit("Waiting for failover slot sync on standby", {standby: standby.ubid})
      nap 10
    end

    hop_test_postgres_before_read_replica
  end

  label def test_postgres_before_read_replica
    Clog.emit("Testing Postgres before read replica creation")
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries before read replica"})
      hop_destroy
    end

    hop_create_read_replica
  end

  label def create_read_replica
    Clog.emit("Creating read replica for upgrade test")

    # Create read replica using the PostgresResourceNexus with parent_id
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id: frame["location_id"],
      parent_id: postgres_resource.id,
      name: "postgres-test-upgrade-replica",
      target_vm_size: postgres_resource.target_vm_size,
      target_storage_size_gib: postgres_resource.target_storage_size_gib,
      user_config: {},
      pgbouncer_user_config: {},
    )

    update_stack({"read_replica_id" => st.id})
    hop_wait_read_replica
  end

  label def wait_read_replica
    nap 10 if !read_replica || read_replica.servers.count != read_replica.target_server_count || read_replica.servers.filter { it.strand.label != "wait" }.any?
    hop_test_postgres_with_read_replica
  end

  label def test_postgres_with_read_replica
    Clog.emit("Testing Postgres with read replica before upgrade")

    # Test primary
    unless representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on primary before upgrade"})
      hop_destroy
    end

    # Test read replica
    unless read_replica.representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on replica before upgrade"})
      hop_destroy
    end

    Clog.emit("Verified both primary and read replica are working correctly")
    hop_trigger_upgrade
  end

  label def trigger_upgrade
    Clog.emit("Starting upgrade from version #{start_version} to #{target_version}")
    Clog.emit("Postgres servers before upgrade: #{postgres_resource.servers.map { [it.ubid, it.version, it.timeline_access, it.strand.label].inspect }.join(", ")}")
    Clog.emit("Read replica servers before upgrade: #{read_replica.servers.map { [it.ubid, it.version, it.timeline_access, it.strand.label].inspect }.join(", ")}")

    postgres_resource.update(target_version:)
    postgres_resource.read_replicas_dataset.update(target_version:)

    hop_check_upgrade_progress
  end

  label def check_upgrade_progress
    Clog.emit("Checking upgrade progress...")
    Clog.emit("Primary server: version=#{representative_server.version}, target=#{postgres_resource.target_version}, state=#{representative_server.strand.label}")

    postgres_resource.servers.each do |server|
      Clog.emit("Server #{server.ubid}: version=#{server.version}, target=#{postgres_resource.target_version}, access=#{server.timeline_access}, state=#{server.strand.label}")
    end

    read_replica.servers.each do |server|
      Clog.emit("Replica server #{server.ubid}: version=#{server.version}, target=#{read_replica.target_version}, access=#{server.timeline_access}, state=#{server.strand.label}")
    end

    # Log timeline and backup information for debugging
    all_servers = postgres_resource.servers + read_replica.servers
    all_servers.map(&:timeline).uniq.each do |timeline|
      backup_count = timeline.backups.count
      Clog.emit("Timeline #{timeline.ubid}: backups_count=#{backup_count}, blob_storage=#{timeline.blob_storage&.url || "none"}")
    end

    # Log LSN catch-up details for servers stuck in wait_catch_up
    all_servers.each do |server|
      next unless server.strand.label == "wait_catch_up"

      begin
        parent_server = if server.read_replica?
          server.resource.parent.representative_server
        else
          server.resource.representative_server
        end

        server_lsn = server.current_lsn
        parent_lsn = parent_server.current_lsn
        diff_bytes = server.lsn_diff(parent_lsn, server_lsn)
        Clog.emit("Server #{server.ubid} in wait_catch_up: server_lsn=#{server_lsn.chomp}, parent_lsn=#{parent_lsn.chomp}, diff_bytes=#{diff_bytes}, threshold=#{80 * 1024 * 1024}, parent_server=#{parent_server.ubid}, parent_state=#{parent_server.strand.label}")
      rescue => ex
        Clog.emit("Failed to fetch LSN info for server #{server.ubid} in wait_catch_up: #{ex.message}")
      end
    end

    # Check if all servers have been upgraded
    primary_upgraded = postgres_resource.servers.all? { |s| s.version == target_version && s.strand.label == "wait" }
    replica_upgraded = read_replica.servers.all? { |s| s.version == target_version && s.strand.label == "wait" }

    if primary_upgraded && replica_upgraded
      Clog.emit("Upgrade completed successfully!")
      hop_test_postgres_after_upgrade
    end

    # Check for any failed states
    failed_servers = (postgres_resource.servers + read_replica.servers).filter { |s| s.strand.label == "failed" }
    if failed_servers.any?
      update_stack({"fail_message" => "Upgrade failed: some servers are in failed state"})
      failed_servers.each do |server|
        Clog.emit("Failed server: #{server.ubid}, version=#{server.version}, state=#{server.strand.label}")
      end
      hop_destroy
    end

    nap 60
  end

  label def test_postgres_after_upgrade
    Clog.emit("Testing Postgres after upgrade to version #{target_version}")
    Clog.emit("Final server states:")
    Clog.emit("Primary servers: #{postgres_resource.servers.map { |s| "[#{s.ubid}, v#{s.version}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")
    Clog.emit("Replica servers: #{read_replica.servers.map { |s| "[#{s.ubid}, v#{s.version}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")

    unless postgres_resource.servers.all? { |s| s.version == target_version }
      update_stack({"fail_message" => "Not all primary servers upgraded to version #{target_version}"})
      hop_destroy
    end

    unless read_replica.servers.all? { |s| s.version == target_version }
      update_stack({"fail_message" => "Not all replica servers upgraded to version #{target_version}"})
      hop_destroy
    end

    # Test read queries on primary (data should still be there)
    Clog.emit("Running read queries on primary after upgrade")
    unless representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on primary after upgrade"})
      hop_destroy
    end

    # Test read queries on read replica
    Clog.emit("Running read queries on replica after upgrade")
    unless read_replica.representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on replica after upgrade"})
      hop_destroy
    end

    # Test write queries on primary
    Clog.emit("Running write queries on primary after upgrade")
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run write queries after upgrade"})
      hop_destroy
    end

    # Verify replica can still read the new data
    Clog.emit("Verifying replica can read updated data")
    unless read_replica.representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to read updated data on replica after upgrade"})
      hop_destroy
    end

    # PG17+ pg_upgrade preserves failover-enabled logical slots
    # PG16 pg_upgrade drops logical slots, assert slot is gone
    Clog.emit("Verifying logical slot state after upgrade")
    slot_row = representative_server.run_query("SELECT failover FROM pg_replication_slots WHERE slot_name = 'upgrade_test_slot'").strip
    expected_row = (start_version.to_i >= 17) ? "t" : ""
    unless slot_row == expected_row
      update_stack({"fail_message" => "Unexpected slot state after upgrade from v#{start_version}: expected #{expected_row.inspect}, got #{slot_row.inspect}"})
      hop_destroy
    end

    Clog.emit("All upgrade tests passed successfully!")
    hop_destroy
  end

  label def destroy_postgres
    primary_timeline_ids = postgres_resource.servers.map(&:timeline_id)
    replica_timeline_ids = read_replica ? read_replica.servers.map(&:timeline_id) : []
    update_stack({"timeline_ids" => (primary_timeline_ids + replica_timeline_ids).uniq})
    read_replica&.incr_destroy
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if read_replica || postgres_resource
    nap_if_private_subnet
    nap_if_gcp_vpc
    verify_timelines_destroyed(frame["timeline_ids"]) if frame["timeline_ids"]
    hop_finish
  end

  label :finish
  label :failed
  label :destroy

  def read_replica
    @read_replica ||= PostgresResource[frame["read_replica_id"]]
  end

  def start_version
    frame["start_version"]
  end

  def target_version
    (start_version.to_i + 1).to_s
  end
end
