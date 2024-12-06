# frozen_string_literal: true

class Prog::Kubernetes::KubernetesVmNexus < Prog::Base
  subject_is :vm

  def self.assemble(vm, commands)
    @commands = commands
    Strand.create(prog: "Kubernetes::KubernetesVmNexus", label: "wait") { _1.id = vm.id }
  end

  label def start
    @commands.map { |command| vm.sshable.cmd command }
    hop_destory
  end

  label def wait
    if vm.display_state != "running"
      nap 5
    end
    hop_start
  end

  label def destroy
    pop "done"
  end
end
