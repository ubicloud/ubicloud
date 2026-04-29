# frozen_string_literal: true

require "net/http"
require "uri"

class Prog::Test::PostgresFirewall < Prog::Test::PostgresBase
  semaphore :destroy

  def self.assemble(provider: "metal", family: nil)
    super(provider:, family:, project_name: "Postgres-Firewall-Test-Project")
  end

  label def start
    super(name: "pg-fw-test")
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
    wait_firewall_rules_applied

    vm = representative_server.vm
    test_pg_connection(vm, should_succeed: true)

    fw_rules = postgres_resource.pg_firewall_rules
    runner_ip = frame["runner_ip"]
    expected_cidrs = [runner_ip, vm.ip4_string].compact.uniq.map { "#{it}/32" }
    actual_cidrs = fw_rules.map { it.cidr.to_s }.uniq
    unless actual_cidrs.sort == expected_cidrs.sort
      update_stack({"fail_message" => "Expected firewall CIDRs #{expected_cidrs} but got #{actual_cidrs}"})
    end

    hop_test_block_all_rules
  end

  label def test_block_all_rules
    # Set a block-all posture by clearing the rule set. With no allow
    # rules, no ingress is permitted, so we do not need to enumerate
    # and exclude the runner IP.
    firewall = postgres_resource.customer_firewall
    firewall.replace_firewall_rules([])

    hop_wait_block_all_applied
  end

  label def wait_block_all_applied
    wait_firewall_rules_applied

    vm = representative_server.vm
    test_pg_connection(vm, should_succeed: false)

    hop_test_restore_open_rules
  end

  label def test_restore_open_rules
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
    wait_firewall_rules_applied

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
    nap_if_private_subnet
    nap_if_gcp_vpc
    verify_timelines_destroyed(frame["timeline_ids"]) if frame["timeline_ids"]
    hop_destroy
  end

  label def destroy
    postgres_test_project.destroy unless Config.local_e2e_postgres_test_project_id
    fail_test(frame["fail_message"]) if frame["fail_message"]
    pop "Postgres firewall tests are finished!"
  end

  label def failed
    nap 15
  end

  def test_pg_connection(vm, should_succeed:)
    ip = vm.ip4_string
    begin
      vm.sshable.cmd("nc -zvw 5 :ip 5432", ip:)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS
      if should_succeed
        retries = (frame.dig("pg_retries", "connect") || 0) + 1
        if retries < 10
          update_stack({"pg_retries" => (frame["pg_retries"] || {}).merge("connect" => retries)})
          nap 15
        end
        update_stack({"pg_retries" => nil, "fail_message" => "Connection to #{ip}:5432 should have succeeded after #{retries} attempts"})
      elsif frame.dig("pg_retries", "block")
        # nc was blocked as expected. Reset the negative-path retry
        # counter so a future phase that calls back here starts fresh.
        update_stack({"pg_retries" => frame["pg_retries"].merge("block" => nil)})
      end
    else
      # nc reached port 5432. Reset the per-phase retry counter so the
      # next positive-path test_pg_connection caller starts from zero.
      pg_retries = frame["pg_retries"]
      pg_retries = pg_retries.merge("connect" => nil) if pg_retries&.[]("connect")
      hash = {}
      hash["pg_retries"] = pg_retries if pg_retries != frame["pg_retries"]
      unless should_succeed
        # GCP dataplane propagation can lag the API ACK by tens of
        # seconds, so a single nc success is not yet a verdict. Retry
        # with the same shape as the success path before giving up.
        retries = (pg_retries&.[]("block") || 0) + 1
        if retries < 10
          hash["pg_retries"] = (pg_retries || {}).merge("block" => retries)
          update_stack(hash)
          nap 15
        end
        hash["pg_retries"] = nil
        hash["fail_message"] = "Connection to #{ip}:5432 should have been blocked after #{retries} attempts"
      end
      update_stack(hash) unless hash.empty?
    end
  end
end
