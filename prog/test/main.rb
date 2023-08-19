# frozen_string_literal: true

require "net/ssh"

# st2 = Strand.create_with_id(prog: 'Test::Main', label: 'start', stack: [{subject_id: VmHost.first.id}])

class Prog::Test::Main < Prog::Base
  subject_is :sshable, :vm_host

  def start
    project = Project.create_with_id(name: "project 1", provider: "hetzner")
    project.create_hyper_tag(project)

    subnet1_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-first-subnet", location: "hetzner-hel1"
    )
    nic1_s = Prog::Vnet::NicNexus.assemble(subnet1_s.id, name: "nic-1")
    nic2_s = Prog::Vnet::NicNexus.assemble(subnet1_s.id, name: "nic-2")

    subnet2_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-second-subnet", location: "hetzner-hel1"
    )
    nic3_s = Prog::Vnet::NicNexus.assemble(subnet2_s.id, name: "nic-3")

    strand.add_child(subnet1_s)
    strand.add_child(subnet2_s)
    strand.add_child(nic1_s)
    strand.add_child(nic2_s)
    strand.add_child(nic3_s)

    keypair_1 = SshKey.generate
    keypair_2 = SshKey.generate
    keypair_3 = SshKey.generate

    vm1_s = Prog::Vm::Nexus.assemble(
      keypair_1.public_key, project.id,
      private_subnet_id: subnet1_s.id,
      nic_id: nic1_s.id,
      enable_ip4: true
    )

    vm2_s = Prog::Vm::Nexus.assemble(
      keypair_2.public_key, project.id,
      private_subnet_id: subnet1_s.id,
      nic_id: nic2_s.id,
      enable_ip4: true
    )

    vm3_s = Prog::Vm::Nexus.assemble(
      keypair_3.public_key, project.id,
      private_subnet_id: subnet2_s.id,
      nic_id: nic3_s.id,
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

    current_frame = strand.stack.first
    current_frame["vms"] = [vm1_s.id, vm2_s.id, vm3_s.id]
    current_frame["subnets"] = [subnet1_s.id, subnet2_s.id]
    current_frame["nics"] = [nic1_s.id, nic2_s.id, nic3_s.id]
    current_frame["project_id"] = project.id
    strand.modified!(:stack)
    strand.save_changes

    hop :wait_children_created
  end

  def children_idle
    active_children = strand.children_dataset.where(Sequel.~(label: "wait"))
    active_semaphores = strand.children_dataset.join(:semaphore, strand_id: :id)

    active_children.count == 0 and active_semaphores.count == 0
  end

  def wait_children_created
    reap

    hop :children_ready if children_idle

    donate
  end

  def children_ready
    current_frame = strand.stack.first
    current_frame["vms"].each { |vm_id|
      Sshable[vm_id].update(host: Vm[vm_id].ephemeral_net4.to_s)
    }

    # add sub-tests
    strand.add_child(
      Strand.create_with_id(
        prog: "Test::Vm",
        label: "start",
        stack: [{subject_id: current_frame["vms"].first}]
      )
    )

    hop :wait_subtests
  end

  def wait_subtests
    reap

    hop :destroy_vms if children_idle

    donate
  end

  def destroy_vms
    current_frame = strand.stack.first
    current_frame["vms"].each { |vm_id|
      Vm[vm_id].incr_destroy
      Sshable[vm_id].destroy
    }

    hop :wait_vms_destroyed
  end

  def wait_vms_destroyed
    reap

    hop :destroy_subnets if children_idle

    donate
  end

  def destroy_subnets
    current_frame = strand.stack.first
    current_frame["subnets"].each { |subnet_id|
      PrivateSubnet[subnet_id].incr_destroy
    }

    hop :wait_subnets_destroyed
  end

  def wait_subnets_destroyed
    reap

    hop :finish if children_idle

    donate
  end

  def finish
    current_frame = strand.stack.first
    Project[current_frame["project_id"]].destroy

    pop "Tests finished!"
  end
end
