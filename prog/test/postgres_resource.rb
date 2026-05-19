# frozen_string_literal: true

class Prog::Test::PostgresResource < Prog::Test::PostgresBase
  semaphore :pause, :destroy

  def self.assemble(provider: "metal", **)
    super(provider:, project_name: "Postgres-Test-Project", **)
  end

  label def start
    super(name: "postgres-test-standard")
  end

  label def wait_postgres_resource
    if postgres_resource.strand.label == "wait" &&
        representative_server.run_query("SELECT 1") == "1"
      hop_test_postgres
    else
      nap 10
    end
  end

  label def test_postgres
    unless representative_server.run_query(test_queries_sql) == "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1"
      update_stack({"fail_message" => "Failed to run test queries"})
    end

    hop_test_vm_restart
  end

  label def test_vm_restart
    vm = representative_server.vm
    unless frame["restart_triggered"]
      vm.incr_restart
      update_stack({"restart_triggered" => true, "restart_deadline" => Time.now.to_i + 10 * 60})
      nap 5
    end

    if Time.now.to_i >= frame["restart_deadline"]
      update_stack({"fail_message" => "VM did not recover from restart within 10 minutes"})
      hop_destroy
    end

    if vm.strand.reload.label == "wait" && postgres_responds?
      hop_destroy
    end

    nap 5
  end

  def postgres_responds?
    representative_server.run_query("SELECT 1") == "1"
  rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshTimeout
    false
  end

  label def destroy_postgres
    update_stack({"timeline_ids" => postgres_resource.servers_dataset.distinct.select_map(:timeline_id)})
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    nap_if_private_subnet
    nap_if_gcp_vpc
    verify_timelines_destroyed(frame["timeline_ids"]) if frame["timeline_ids"]

    hop_finish
  end

  label :finish
  label :failed
  label :destroy
end
