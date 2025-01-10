# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::PostgresResource < Prog::Test::Base
  semaphore :destroy

  def self.assemble(test_case, vm_host_id, postgres_test_project_id)
    Strand.create_with_id(
      prog: "Test::PostgresResource",
      label: "start",
      stack: [{
        "postgres_test_project_id" => postgres_test_project_id,
        "vm_host_id" => vm_host_id,
        "test_case" => test_case
      }]
    )
  end

  label def start
    hop_download_boot_image
  end

  label def download_boot_image
    flavor = "-#{tests[test_case]["postgres_flavor"]}"
    flavor = "" if flavor == "-standard"
    image_name = "postgres#{tests[test_case]["postgres_version"]}#{flavor}-ubuntu-2204"
    vm_host = VmHost[vm_host_id]

    # Download the boot image if it does not exist on the VM host.
    bud Prog::DownloadBootImage, {"subject_id" => vm_host_id, "image_name" => image_name} unless vm_host.boot_images_dataset.where(name: image_name).count > 0

    hop_wait_download_boot_image
  end

  label def wait_download_boot_image
    reap
    hop_create_postgres_resource if leaf?
    donate
  end

  label def create_postgres_resource
    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location: "hetzner-fsn1",
      name: "postgres-test-#{tests[test_case]["postgres_version"]}-#{tests[test_case]["postgres_flavor"]}",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      version: tests[test_case]["postgres_version"],
      flavor: tests[test_case]["postgres_flavor"],
      ha_type: tests[test_case]["ha_type"]
    )

    update_stack({"postgres_resource_id" => st.id})
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    if postgres_resource.strand.label == "wait" &&
        postgres_resource.representative_server.run_query("SELECT 1") == "1"
      hop_test_basic_connectivity
    else
      nap 10
    end
  end

  label def test_basic_connectivity
    server = postgres_resource.representative_server

    # Basic connectivity test
    result = server.run_query("SELECT 1")

    unless result == "1"
      update_stack({"fail_message" => "Basic connectivity test failed"})
      hop_destroy
    end

    hop_test_table_create
  end

  label def test_table_create
    server = postgres_resource.representative_server

    unless server.run_query(sample_create_table_sql)
      update_stack({"fail_message" => "Failed to create table"})
      hop_destroy
    end

    hop_test_table_insert
  end

  label def test_table_insert
    server = postgres_resource.representative_server
    unless server.run_query(sample_data_insert_sql)
      update_stack({"fail_message" => "Failed to insert data into table"})
      hop_destroy
    end

    hop_test_aggregate_queries
  end

  label def test_aggregate_queries
    server = postgres_resource.representative_server

    unless server.run_query(sample_test_queries_sql) == "4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run aggregate queries"})
    end

    hop_destroy
  end

  label def destroy
    postgres_resource.incr_destroy

    frame["fail_message"] ? fail_test(frame["fail_message"]) : hop_finish
  end

  label def finish
    pop "success"
  end

  label def failed
  end

  def tests
    @tests ||= YAML.load_file("config/postgres_e2e_tests.yml").to_h { [_1["name"], _1] }
  end

  def test_case
    @test_case ||= frame["test_case"]
  end

  def vm_host_id
    @vm_host_id ||= frame["vm_host_id"] || VmHost.first.id
  end

  def postgres_resource
    @postgres_resource ||= PostgresResource[frame["postgres_resource_id"]]
  end

  def sample_create_table_sql
    File.read("./prog/test/testdata/order_analytics_table.sql")
  end

  def sample_data_insert_sql
    File.read("./prog/test/testdata/order_analytics_data.sql")
  end

  def sample_test_queries_sql
    File.read("./prog/test/testdata/order_analytics_queries.sql")
  end
end
