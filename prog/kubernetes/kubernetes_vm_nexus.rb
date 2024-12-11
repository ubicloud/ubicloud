# frozen_string_literal: true

class Prog::Kubernetes::KubernetesVmNexus < Prog::Base
  subject_is :kubernetes_vm
  semaphore :destroy

  def self.assemble(unix_user:, project_id:, location:, name:, size:, storage_size:, boot_image:, private_subnet_id:, enable_ip4:, commands:)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        unix_user, project_id,
        location: location,
        name: name,
        size: size,
        storage_volumes: [
          {encrypted: true, size_gib: storage_size}
        ],
        boot_image: boot_image,
        private_subnet_id: private_subnet_id,
        enable_ip4: enable_ip4,
        allow_only_ssh: true
      )

      kv = KubernetesVm.create_with_id(
        vm_id: vm_st.id
      )
      kv.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesVmNexus", label: "wait", stack: [{commands: commands}]) { _1.id = kv.id }
    end
  end

  label def start
    when_destroy_set? do
      hop_destroy
    end
    frame["commands"].map { |command| kubernetes_vm.vm.sshable.cmd command }
    hop_sleep
  end

  label def wait
    if kubernetes_vm.vm.display_state != "running"
      nap 5
    end
    hop_start
  end

  label def sleep
    nap 30
  end

  label def destroy
    decr_destroy

    kubernetes_vm.vm.incr_destroy unless kubernetes_vm.vm.nil?
    pop "kubernetes vm is deleted"
  end
end
