# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::UpgradePostgresResource < Prog::Test::PostgresBase
  def self.assemble(provider: "metal")
    super(provider:, project_name: "Postgres-Upgrade-Test-Project")
  end

  label def start
    location_id, target_vm_size, target_storage_size_gib = self.class.postgres_test_location_options(frame["provider"])

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      name: "postgres-test-upgrade",
      target_vm_size:,
      target_storage_size_gib:,
      ha_type: "async",
      target_version: "17",
    )

    update_stack({"postgres_resource_id" => st.id, "private_subnet_id" => st.subject.private_subnet_id})
    update_stack({"pre_upgrade_postgres_timeline_id" => PostgresResource[st.id].timeline.id})
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    servers = postgres_resource.servers
    nap 10 if servers.count != postgres_resource.target_server_count || servers.filter { it.strand.label != "wait" }.any?
    hop_test_postgres_before_read_replica
  end

  label def test_postgres_before_read_replica
    Clog.emit("Testing Postgres before read replica creation")
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries before read replica"})
      hop_destroy_postgres
    end

    hop_create_read_replica
  end

  label def create_read_replica
    Clog.emit("Creating read replica for upgrade test")

    location_id, target_vm_size, target_storage_size_gib = self.class.postgres_test_location_options(frame["provider"])

    # Create read replica using the PostgresResourceNexus with parent_id
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      parent_id: postgres_resource.id,
      name: "postgres-test-upgrade-replica",
      target_vm_size:,
      target_storage_size_gib:,
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
      hop_destroy_postgres
    end

    # Test read replica
    unless read_replica.representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on replica before upgrade"})
      hop_destroy_postgres
    end

    Clog.emit("Verified both primary and read replica are working correctly")
    hop_trigger_upgrade
  end

  label def trigger_upgrade
    Clog.emit("Starting upgrade from version 17 to 18")
    Clog.emit("Postgres servers before upgrade: #{postgres_resource.servers.map { [it.ubid, it.version, it.timeline_access, it.strand.label].inspect }.join(", ")}")
    Clog.emit("Read replica servers before upgrade: #{read_replica.servers.map { [it.ubid, it.version, it.timeline_access, it.strand.label].inspect }.join(", ")}")

    postgres_resource.update(target_version: "18")
    postgres_resource.read_replicas_dataset.update(target_version: "18")

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

    # Check if all servers have been upgraded to version 18
    primary_upgraded = postgres_resource.servers.all? { |s| s.version == "18" && s.strand.label == "wait" }
    replica_upgraded = read_replica.servers.all? { |s| s.version == "18" && s.strand.label == "wait" }

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
      hop_destroy_postgres
    end

    nap 60
  end

  label def test_postgres_after_upgrade
    Clog.emit("Testing Postgres after upgrade to version 18")
    Clog.emit("Final server states:")
    Clog.emit("Primary servers: #{postgres_resource.servers.map { |s| "[#{s.ubid}, v#{s.version}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")
    Clog.emit("Replica servers: #{read_replica.servers.map { |s| "[#{s.ubid}, v#{s.version}, #{s.timeline_access}, #{s.strand.label}]" }.join(", ")}")

    # Verify all servers are at version 18
    unless postgres_resource.servers.all? { |s| s.version == "18" }
      update_stack({"fail_message" => "Not all primary servers upgraded to version 18"})
      hop_destroy_postgres
    end

    unless read_replica.servers.all? { |s| s.version == "18" }
      update_stack({"fail_message" => "Not all replica servers upgraded to version 18"})
      hop_destroy_postgres
    end

    # Test read queries on primary (data should still be there)
    Clog.emit("Running read queries on primary after upgrade")
    unless representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on primary after upgrade"})
      hop_destroy_postgres
    end

    # Test read queries on read replica
    Clog.emit("Running read queries on replica after upgrade")
    unless read_replica.representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run read queries on replica after upgrade"})
      hop_destroy_postgres
    end

    # Test write queries on primary (should work on v18)
    Clog.emit("Running write queries on primary after upgrade")
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run write queries after upgrade"})
      hop_destroy_postgres
    end

    # Verify replica can still read the new data
    Clog.emit("Verifying replica can read updated data")
    unless read_replica.representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to read updated data on replica after upgrade"})
      hop_destroy_postgres
    end

    Clog.emit("All upgrade tests passed successfully!")
    hop_destroy_postgres
  end

  label def destroy_postgres
    pre_upgrade_timeline.incr_destroy
    postgres_resource.timeline.incr_destroy
    read_replica.incr_destroy
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if read_replica || postgres_resource || pre_upgrade_timeline
    nap_if_private_subnet
    hop_finish
  end

  label :finish
  label :failed

  def read_replica
    @read_replica ||= PostgresResource[frame["read_replica_id"]]
  end

  def pre_upgrade_timeline
    PostgresTimeline[frame["pre_upgrade_postgres_timeline_id"]]
  end
end
