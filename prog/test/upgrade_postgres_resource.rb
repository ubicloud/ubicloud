# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::UpgradePostgresResource < Prog::Test::Base
  semaphore :destroy

  def self.assemble(provider: "metal", family: nil)
    postgres_test_project = Project.create(name: "Postgres-Upgrade-Test-Project")

    frame = {
      "provider" => provider,
      "family" => family,
      "postgres_test_project_id" => postgres_test_project.id
    }

    Strand.create(
      prog: "Test::UpgradePostgresResource",
      label: "start",
      stack: [frame]
    )
  end

  label def start
    location_id, target_vm_size, target_storage_size_gib = if frame["provider"] == "aws"
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      unless LocationCredential[location.id]
        LocationCredential.create_with_id(location.id, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      end
      family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    elsif frame["provider"] == "gcp"
      location = Location[provider: "gcp", project_id: nil]
      unless LocationCredential[location.id]
        LocationCredential.create_with_id(location.id,
          credentials_json: Config.e2e_gcp_credentials_json,
          project_id: Config.e2e_gcp_project_id,
          service_account_email: Config.e2e_gcp_service_account_email)
      end
      family = frame["family"]
      if family && Option::GCP_FAMILY_OPTIONS.include?(family)
        vcpus = Option::GCP_STORAGE_SIZE_OPTIONS[family].keys.first
        [location.id, "#{family}-#{vcpus}", Option::GCP_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
      else
        [location.id, "standard-2", 128]
      end
    else
      [Location::HETZNER_FSN1_ID, "standard-2", 128]
    end

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      name: "postgres-test-upgrade",
      target_vm_size:,
      target_storage_size_gib:,
      ha_type: "async",
      target_version: "17"
    )

    update_stack({"postgres_resource_id" => st.id, "location_id" => location_id})
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

    # Create read replica using the PostgresResourceNexus with parent_id
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id: frame["location_id"],
      parent_id: postgres_resource.id,
      name: "postgres-test-upgrade-replica",
      target_vm_size: postgres_resource.target_vm_size,
      target_storage_size_gib: postgres_resource.target_storage_size_gib,
      user_config: {},
      pgbouncer_user_config: {}
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
    primary_timeline_ids = postgres_resource.servers.map(&:timeline_id)
    replica_timeline_ids = read_replica ? read_replica.servers.map(&:timeline_id) : []
    update_stack({"timeline_ids" => (primary_timeline_ids + replica_timeline_ids).uniq})
    read_replica&.incr_destroy
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if read_replica || postgres_resource
    if PrivateSubnet[project_id: frame["postgres_test_project_id"]]
      Clog.emit("Waiting for private subnet to be destroyed")
      nap 5
    end

    # Timelines are retained for 10 days after resource destruction for
    # customer recovery. Verify they still exist, then explicitly destroy
    # them to test timeline cleanup.
    remaining_timelines = (frame["timeline_ids"] || []).filter_map { PostgresTimeline[it] }
    if remaining_timelines.any?
      Clog.emit("Verifying timelines are retained after resource destroy (found #{remaining_timelines.count})")
      remaining_timelines.each(&:incr_destroy)
      nap 5
    end

    hop_destroy
  end

  label def destroy
    postgres_test_project.destroy

    fail_test(frame["fail_message"]) if frame["fail_message"]

    pop "Postgres upgrade tests are finished!"
  end

  label def failed
    nap 15
  end

  def postgres_test_project
    Project[frame["postgres_test_project_id"]]
  end

  def postgres_resource
    PostgresResource[frame["postgres_resource_id"]]
  end

  def read_replica
    @read_replica ||= PostgresResource[frame["read_replica_id"]]
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
