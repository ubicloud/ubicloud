# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(sshable_hostname, location: "hetzner-hel1", net6: nil)
    DB.transaction do
      sa = Sshable.create(host: sshable_hostname)
      VmHost.create(location: location, net6: net6) { _1.id = sa.id }

      Strand.create(prog: "Vm::HostNexus", label: "start") { _1.id = sa.id }
    end
  end

  def start
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
    bud Prog::InstallDnsmasq
    hop :wait_prep
  end

  def wait_prep
    reap.each do |st|
      case st.fetch(:prog)
      when "LearnMemory"
        fail "BUG" unless (mem_gib = st.dig(:exitval, "mem_gib"))
        vm_host.update(total_mem_gib: mem_gib)
      when "LearnCores"
        fail "BUG" unless (total_sockets = st.dig(:exitval, "total_sockets"))
        fail "BUG" unless (total_nodes = st.dig(:exitval, "total_nodes"))
        fail "BUG" unless (total_cores = st.dig(:exitval, "total_cores"))
        fail "BUG" unless (total_cpus = st.dig(:exitval, "total_cpus"))

        vm_host.update(total_sockets: total_sockets, total_nodes: total_nodes,
          total_cores: total_cores, total_cpus: total_cpus)
      end
    end

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
