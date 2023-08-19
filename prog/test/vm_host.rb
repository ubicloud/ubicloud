# frozen_string_literal: true

require "net/ssh"

class Prog::Test::VmHost < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    hop_setup_vms
  end

  label def setup_vms
    project = Project.create_with_id(name: "project 1", provider: "hetzner")
    project.create_hyper_tag(project)

    subnet1_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-first-subnet", location: "hetzner-hel1"
    )

    subnet2_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-second-subnet", location: "hetzner-hel1"
    )

    strand.add_child(subnet1_s)
    strand.add_child(subnet2_s)

    keypair_1 = SshKey.generate
    keypair_2 = SshKey.generate
    keypair_3 = SshKey.generate

    vm1_s = Prog::Vm::Nexus.assemble(
      keypair_1.public_key, project.id,
      private_subnet_id: subnet1_s.id,
      enable_ip4: true
    )

    vm2_s = Prog::Vm::Nexus.assemble(
      keypair_2.public_key, project.id,
      private_subnet_id: subnet1_s.id,
      enable_ip4: true
    )

    vm3_s = Prog::Vm::Nexus.assemble(
      keypair_3.public_key, project.id,
      private_subnet_id: subnet2_s.id,
      enable_ip4: true
    )

    Sshable.create(
      unix_user: "ubi",
      host: "temp_#{vm1_s.id}",
      raw_private_key_1: keypair_1.keypair
    ) { _1.id = vm1_s.id }

    Sshable.create(
      unix_user: "ubi",
      host: "temp_#{vm2_s.id}",
      raw_private_key_1: keypair_2.keypair
    ) { _1.id = vm2_s.id }

    Sshable.create(
      unix_user: "ubi",
      host: "temp_#{vm3_s.id}",
      raw_private_key_1: keypair_3.keypair
    ) { _1.id = vm3_s.id }

    strand.add_child(vm1_s)
    strand.add_child(vm2_s)
    strand.add_child(vm3_s)
    strand.add_child(Strand[vm1_s.vm.nics.first.id])
    strand.add_child(Strand[vm2_s.vm.nics.first.id])
    strand.add_child(Strand[vm3_s.vm.nics.first.id])

    current_frame = strand.stack.first
    current_frame["vms"] = [vm1_s.id, vm2_s.id, vm3_s.id]
    current_frame["subnets"] = [subnet1_s.id, subnet2_s.id]
    current_frame["project_id"] = project.id
    strand.modified!(:stack)
    strand.save_changes

    hop_wait_children_created
  end

  label def wait_children_created
    reap

    hop_children_ready if children_idle

    donate
  end

  label def children_ready
    frame["vms"].each { |vm_id|
      Sshable[vm_id].update(host: Vm[vm_id].ephemeral_net4.to_s)
    }

    # add sub-tests
    strand.add_child(
      Strand.create_with_id(
        prog: "Test::Vm",
        label: "start",
        stack: [{subject_id: frame["vms"].first}]
      )
    )

    hop_wait_subtests
  end

  label def wait_subtests
    reap

    hop_destroy_vms if children_idle

    donate
  end

  label def destroy_vms
    frame["vms"].each { |vm_id|
      Vm[vm_id].incr_destroy
      Sshable[vm_id].destroy
    }

    hop_wait_vms_destroyed
  end

  label def wait_vms_destroyed
    reap

    hop_destroy_subnets if children_idle

    donate
  end

  label def destroy_subnets
    frame["subnets"].each { |subnet_id|
      PrivateSubnet[subnet_id].incr_destroy
    }

    hop_wait_subnets_destroyed
  end

  label def wait_subnets_destroyed
    reap

    finish if children_idle

    donate
  end

  label def finish
    Project[frame["project_id"]].destroy
    pop "VmHost tests finished!"
  end

  def children_idle
    active_children = strand.children_dataset.where(Sequel.~(label: "wait"))
    active_semaphores = strand.children_dataset.join(:semaphore, strand_id: :id)

    active_children.count == 0 and active_semaphores.count == 0
  end
end
