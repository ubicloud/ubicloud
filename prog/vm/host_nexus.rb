# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(sshable_hostname, location: "hetzner-hel1", net6: nil, ndp_needed: false, provider: nil, hetzner_server_identifier: nil)
    DB.transaction do
      ubid = VmHost.generate_ubid

      Sshable.create(host: sshable_hostname) { _1.id = ubid.to_uuid }
      vmh = VmHost.create(location: location, net6: net6, ndp_needed: ndp_needed) { _1.id = ubid.to_uuid }

      if provider == HetznerHost::PROVIDER_NAME
        HetznerHost.create(server_identifier: hetzner_server_identifier) { _1.id = vmh.id }
        vmh.create_addresses
      else
        Address.create(cidr: sshable_hostname, routed_to_host_id: vmh.id) { _1.id = vmh.id }
        AssignedHostAddress.create_with_id(ip: sshable_hostname, address_id: vmh.id, host_id: vmh.id)
      end

      Strand.create(prog: "Vm::HostNexus", label: "start") { _1.id = vmh.id }
    end
  end

  def start
    register_deadline(:wait, 15 * 60)

    bud Prog::BootstrapRhizome
    hop :wait_bootstrap_rhizome
  end

  def wait_bootstrap_rhizome
    reap
    hop :prep if leaf?
    donate
  end

  def prep
    bud Prog::Vm::PrepHost
    bud Prog::LearnNetwork unless vm_host.net6
    bud Prog::LearnMemory
    bud Prog::LearnCores
    bud Prog::LearnStorage
    bud Prog::InstallDnsmasq
    hop :wait_prep
  end

  def wait_prep
    reap.each do |st|
      case st.fetch(:prog)
      when "LearnMemory"
        fail "BUG: mem_gib not set" unless (mem_gib = st.dig(:exitval, "mem_gib"))
        vm_host.update(total_mem_gib: mem_gib)
      when "LearnCores"
        kwargs = {
          total_sockets: st.dig(:exitval, "total_sockets"),
          total_nodes: st.dig(:exitval, "total_nodes"),
          total_cores: st.dig(:exitval, "total_cores"),
          total_cpus: st.dig(:exitval, "total_cpus")
        }

        fail "BUG: one of the LearnCores fields is not set" if kwargs.value?(nil)

        vm_host.update(**kwargs)
      when "LearnStorage"
        kwargs = {
          total_storage_gib: st.dig(:exitval, "total_storage_gib"),
          available_storage_gib: st.dig(:exitval, "available_storage_gib")
        }

        fail "BUG: one of the LearnStorage fields is not set" if kwargs.value?(nil)

        vm_host.update(**kwargs)
      end
    end

    if leaf?
      hop :setup_hugepages
    end
    donate
  end

  def setup_hugepages
    bud Prog::SetupHugepages
    hop :wait_setup_hugepages
  end

  def wait_setup_hugepages
    reap
    hop :setup_spdk if leaf?
    donate
  end

  def setup_spdk
    bud Prog::SetupSpdk
    hop :wait_setup_spdk
  end

  def wait_setup_spdk
    reap
    if leaf?
      vm_host.update(allocation_state: "accepting")
      hop :wait
    end
    donate
  end

  def wait
    nap 30
  end
end
