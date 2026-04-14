# frozen_string_literal: true

require "net/http"
require "uri"

class Prog::Test::PostgresFirewall < Prog::Test::Base
  semaphore :destroy

  def self.assemble(provider: "metal")
    postgres_test_project = Project.create(name: "Postgres-Firewall-Test-Project")
    postgres_service_project = Project[Config.postgres_service_project_id] ||
      Project.create_with_id(Config.postgres_service_project_id || Project.generate_uuid, name: "Postgres-Service-Project")

    frame = {
      "provider" => provider,
      "postgres_service_project_id" => postgres_service_project.id,
      "postgres_test_project_id" => postgres_test_project.id,
    }

    Strand.create(
      prog: "Test::PostgresFirewall",
      label: "start",
      stack: [frame],
    )
  end

  label def start
    location_id, target_vm_size, target_storage_size_gib = e2e_postgres_provider_setup(frame["provider"])

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: frame["postgres_test_project_id"],
      location_id:,
      name: "pg-fw-test",
      target_vm_size:,
      target_storage_size_gib:,
    )

    update_stack({"postgres_resource_id" => st.id})
    hop_wait_postgres_resource
  end

  label def wait_postgres_resource
    if postgres_resource.strand.label == "wait" &&
        representative_server.run_query("SELECT 1") == "1"
      hop_test_default_firewall_rules
    else
      nap 10
    end
  end

  label def test_default_firewall_rules
    # Default rules allow 0.0.0.0/0 and ::/0 on ports 5432 and 6432.
    # Verify the Postgres VM is reachable on port 5432 from this runner.
    vm = representative_server.vm
    vm.sshable.cmd("sudo apt-get update && sudo apt-get install -y netcat-openbsd")
    test_pg_connection(vm, should_succeed: true)

    hop_test_restricted_firewall_rules
  end

  label def test_restricted_firewall_rules
    # Replace the customer firewall rules: only allow our runner's IP.
    # Also allow the VM's own external IP since the test connects from
    # within the VM to its external IP, which traverses the cloud firewall.
    uri = URI("https://api.ipify.org")
    my_ip = Net::HTTP.get(uri)
    vm_ip = representative_server.vm.ip4_string
    update_stack({"runner_ip" => my_ip})

    allowed_ips = [my_ip, vm_ip].compact.uniq
    rules = allowed_ips.flat_map { |ip|
      [
        {cidr: "#{ip}/32", port_range: Sequel.pg_range(5432..5432)},
        {cidr: "#{ip}/32", port_range: Sequel.pg_range(6432..6432)},
      ]
    }
    firewall = postgres_resource.customer_firewall
    firewall.replace_firewall_rules(rules)

    hop_wait_restricted_rules_applied
  end

  label def wait_restricted_rules_applied
    if postgres_resource.private_subnet.update_firewall_rules_set? ||
        postgres_resource.private_subnet.vms.any?(&:update_firewall_rules_set?)
      nap 5
    end

    # Verify we can still connect from the runner.
    vm = representative_server.vm
    test_pg_connection(vm, should_succeed: true)

    # Verify the firewall rules on the resource match what we set.
    fw_rules = postgres_resource.pg_firewall_rules
    runner_ip = frame["runner_ip"]
    expected_cidrs = [runner_ip, vm.ip4_string].compact.uniq.map { "#{it}/32" }
    actual_cidrs = fw_rules.map { it.cidr.to_s }.uniq
    unless actual_cidrs.sort == expected_cidrs.sort
      update_stack({"fail_message" => "Expected firewall CIDRs #{expected_cidrs} but got #{actual_cidrs}"})
    end

    hop_test_restore_open_rules
  end

  label def test_restore_open_rules
    # Restore wide-open rules.
    firewall = postgres_resource.customer_firewall
    firewall.replace_firewall_rules([
      {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(5432..5432)},
      {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(6432..6432)},
      {cidr: "::/0", port_range: Sequel.pg_range(5432..5432)},
      {cidr: "::/0", port_range: Sequel.pg_range(6432..6432)},
    ])

    hop_wait_open_rules_applied
  end

  label def wait_open_rules_applied
    if postgres_resource.private_subnet.update_firewall_rules_set? ||
        postgres_resource.private_subnet.vms.any?(&:update_firewall_rules_set?)
      nap 5
    end

    # Verify connectivity is restored.
    vm = representative_server.vm
    test_pg_connection(vm, should_succeed: true)

    hop_destroy_postgres
  end

  label def destroy_postgres
    update_stack({"timeline_ids" => postgres_resource.servers_dataset.distinct.select_map(:timeline_id)})
    postgres_resource.incr_destroy
    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    nap 5 if postgres_resource
    if PrivateSubnet[project_id: frame["postgres_test_project_id"]]
      Clog.emit("Waiting for private subnet to be destroyed")
      nap 5
    end
    remaining_count = PostgresTimeline.destroy_remaining(frame["timeline_ids"] || [])
    if remaining_count > 0
      Clog.emit("Verifying timelines are retained after resource destroy (found #{remaining_count})")
      nap 5
    end

    hop_destroy
  end

  label def destroy
    postgres_test_project.destroy

    fail_test(frame["fail_message"]) if frame["fail_message"]

    pop "Postgres firewall tests are finished!"
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

  def test_pg_connection(vm, should_succeed:)
    ip = vm.ip4_string
    begin
      vm.sshable.cmd("nc -zvw 5 :ip 5432", ip:)
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError
      if should_succeed
        retries = (frame["pg_connect_retries"] || 0) + 1
        if retries < 10
          update_stack({"pg_connect_retries" => retries})
          nap 15
        end
        update_stack({"fail_message" => "Connection to #{ip}:5432 should have succeeded after #{retries} attempts"})
      end
    else
      unless should_succeed
        update_stack({"fail_message" => "Connection to #{ip}:5432 should have been blocked"})
      end
    end
  end
end
