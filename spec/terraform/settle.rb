# frozen_string_literal: true

# For each table whose rows the API reports as pending until a prog runs,
# settle_<table> does what the control plane would have done by the time
# the object is at rest. The harness runs no progs, so it calls the hook
# after the API accepts any change, including a DELETE, if the object's
# row still exists.
module TerraformHarness::Settle
  module_function

  # A DELETE leaves a load balancer in place until LoadBalancerNexus
  # destroys it, together with its VM memberships and ports.
  def settle_load_balancer(lb)
    lb.destroy if lb.destroy_set?
  end

  # A new database reads as creating until PostgresResourceNexus reaches
  # wait, and a resize, an HA change or an upgrade leaves it needing
  # convergence until ConvergePostgresResource replaces its servers in the
  # maintenance window. A DELETE leaves it deleting until its prog
  # destroys its servers and then the database.
  def settle_postgres_resource(pg)
    if pg.destroy_set?
      pg.servers.each(&:destroy)
      return pg.destroy
    end

    pg.strand.update(label: "wait")
    pg.decr_initial_provisioning
    standbys = pg.servers.reject(&:is_representative)
    (pg.target_standby_count - standbys.size).times { pg.provision_new_standby }
    standbys.drop(pg.target_standby_count).each(&:destroy)
    size = Option::VmSizes.find { it.name == pg.target_vm_size.sub("hobby", "burstable") }
    pg.reload.servers.each do |server|
      server.update(version: pg.target_version)
      server.strand.update(label: "wait")
      server.vm.update(family: size.family, vcpus: size.vcpus, memory_gib: size.memory_gib,
        cpu_percent_limit: size.cpu_percent_limit, cpu_burst_percent_limit: size.cpu_burst_percent_limit)
      server.vm.vm_storage_volumes.reject(&:boot).each { it.update(size_gib: pg.target_storage_size_gib) }
    end
  end

  # The API creates a subnet at rest, and a DELETE leaves it deleting until
  # SubnetNexus destroys it.
  def settle_private_subnet(ps)
    ps.destroy if ps.destroy_set?
  end

  # A new VM reads as creating until its prog starts it on a host, and a
  # DELETE leaves it deleting until its prog destroys it and has NicNexus
  # destroy its NICs.
  def settle_vm(vm)
    if vm.destroy_set?
      vm.nics.each(&:destroy)
      vm.destroy
    elsif vm.display_state == "creating"
      vm.update(display_state: "running")
    end
  end
end

RSpec.configure do |config|
  # A database's servers and internal firewall belong to the postgres
  # service project, which the test configuration does not set.
  config.before do
    allow(Config).to receive(:postgres_service_project_id) { @postgres_service_project_id ||= Project.create(name: "postgres-service").id }
  end
end
