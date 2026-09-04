# frozen_string_literal: true

class Prog::Test::PostgresImageFamily < Prog::Test::PostgresBase
  semaphore :pause, :destroy
  frame_reader :from_image_family, :to_image_family
  frame_accessor :pre_migration_timeline_id

  def self.assemble(provider: "metal", from_image_family: "ubuntu-2204", to_image_family: "ubuntu-2604", **)
    st = super(provider:, project_name: "Postgres-Image-Family-Test-Project", **)
    st.update(stack: [st.stack.first.merge("from_image_family" => from_image_family, "to_image_family" => to_image_family)])
    st
  end

  label def start
    super(name: "postgres-test-image-family", target_image_family: from_image_family)
  end

  label def wait_postgres_resource
    if postgres_resource.strand.label == "wait" &&
        representative_server.run_query("SELECT 1") == "1"
      hop_verify_initial_image_family
    else
      nap 10
    end
  end

  label def verify_initial_image_family
    unless representative_server.image_family == from_image_family
      self.fail_message = "Representative server runs image family #{representative_server.image_family.inspect}, expected #{from_image_family.inspect}"
      hop_destroy
    end

    hop_populate_data
  end

  label def populate_data
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      self.fail_message = "Failed to run test queries before migration"
      hop_destroy
    end

    hop_trigger_migration
  end

  label def trigger_migration
    self.pre_migration_timeline_id = representative_server.timeline_id
    postgres_resource.update(target_image_family: to_image_family)

    hop_wait_migration
  end

  label def wait_migration
    if postgres_resource.strand.label == "wait" &&
        !postgres_resource.needs_convergence? &&
        representative_server.run_query("SELECT 1") == "1"
      hop_verify_migrated_image_family
    else
      nap 10
    end
  end

  label def verify_migrated_image_family
    unless representative_server.image_family == to_image_family
      self.fail_message = "Representative server runs image family #{representative_server.image_family.inspect}, expected #{to_image_family.inspect}"
      hop_destroy
    end

    hop_verify_data_survived
  end

  label def verify_data_survived
    unless representative_server.run_query(read_queries_sql) == "4159.90\n415.99\n4.1"
      self.fail_message = "Data did not survive the image family migration"
      hop_destroy
    end

    hop_test_postgres
  end

  label def test_postgres
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      self.fail_message = "Failed to run test queries after migration"
    end

    hop_destroy
  end

  label def destroy_postgres
    current_timeline_ids = postgres_resource ? postgres_resource.servers_dataset.distinct.select_map(:timeline_id) : []
    self.timeline_ids = (current_timeline_ids + [pre_migration_timeline_id]).compact.uniq
    super
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    nap_if_gcp_vpc
    nap_if_private_subnet
    verify_timelines_destroyed(timeline_ids) if timeline_ids

    hop_finish
  end

  label :finish
  label :failed
  label :destroy
end
