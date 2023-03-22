# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  def self.assemble(sshable_hostname, location: "hetzner-hel1")
    DB.transaction do
      sa = Sshable.create(host: sshable_hostname)
      VmHost.create(location: location) { _1.id = sa.id }

      Strand.create(prog: "Vm::HostNexus", label: "start") { _1.id = sa.id }
    end
  end

  def vm_host
    @vm_host ||= VmHost[strand.id]
  end

  def start
    bud Prog::BootstrapRhizome, sshable_id: strand.id
    hop :wait_bootstrap_rhizome
  end

  def wait_bootstrap_rhizome
    reap
    hop :install_rhizome if leaf?
    donate
  end

  def install_rhizome
    bud Prog::InstallRhizome, sshable_id: strand.id
    hop :wait_install_rhizome
  end

  def wait_install_rhizome
    reap
    hop :prep if leaf?
    donate
  end

  def prep
    bud Prog::Vm::PrepHost, vmhost_id: strand.id
    bud Prog::LearnNetwork, vmhost_id: strand.id
    hop :wait_prep
  end

  def wait_prep
    reap
    if leaf?
      vm_host.update(allocation_state: "accepting")
      hop :wait
    end
    donate
  end

  def wait
  end
end
