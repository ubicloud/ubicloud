# frozen_string_literal: true

require "net/ssh"

class Prog::Test::VmGroup < Prog::Base
  def self.assemble(storage_encrypted: true, test_reboot: true, use_bdev_ubi: true)
    Strand.create_with_id(
      prog: "Test::VmGroup",
      label: "start",
      stack: [{
        "storage_encrypted" => storage_encrypted,
        "test_reboot" => test_reboot,
        "use_bdev_ubi" => use_bdev_ubi
      }]
    )
  end

  label def start
    hop_setup_vms
  end

  label def setup_vms
    project = Project.create_with_id(name: "project 1", provider: "hetzner")
    project.associate_with_project(project)

    subnet1_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-first-subnet", location: "hetzner-hel1"
    )

    subnet2_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-second-subnet", location: "hetzner-hel1"
    )

    strand.add_child(subnet1_s)
    strand.add_child(subnet2_s)

    storage_encrypted = frame.fetch("storage_encrypted", true)
    use_bdev_ubi = frame.fetch("use_bdev_ubi", true)

    vm1_s = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi", project.id,
      private_subnet_id: subnet1_s.id,
      storage_volumes: [
        {encrypted: storage_encrypted, use_bdev_ubi: use_bdev_ubi, skip_sync: true},
        {encrypted: storage_encrypted, size_gib: 5}
      ],
      enable_ip4: true
    )

    vm2_s = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi", project.id,
      private_subnet_id: subnet1_s.id,
      storage_volumes: [{encrypted: storage_encrypted, use_bdev_ubi: use_bdev_ubi, skip_sync: false}],
      enable_ip4: true
    )

    vm3_s = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi", project.id,
      private_subnet_id: subnet2_s.id,
      storage_volumes: [{encrypted: storage_encrypted, use_bdev_ubi: use_bdev_ubi, skip_sync: false}],
      enable_ip4: true
    )

    strand.add_child(vm1_s)
    strand.add_child(vm2_s)
    strand.add_child(vm3_s)
    strand.add_child(Strand[vm1_s.subject.nics.first.id])
    strand.add_child(Strand[vm2_s.subject.nics.first.id])
    strand.add_child(Strand[vm3_s.subject.nics.first.id])

    current_frame = strand.stack.first
    current_frame["vms"] = [vm1_s.id, vm2_s.id, vm3_s.id]
    current_frame["subnets"] = [subnet1_s.id, subnet2_s.id]
    current_frame["project_id"] = project.id
    strand.modified!(:stack)
    strand.save_changes

    hop_wait_children_ready
  end

  label def wait_children_ready
    reap

    hop_children_ready if children_idle

    donate
  end

  label def children_ready
    frame["vms"].each { |vm_id|
      Sshable[vm_id].update(host: Vm[vm_id].ephemeral_net4.to_s)
    }

    # add sub-tests
    strand.add_child(Prog::Test::Vm.assemble(frame["vms"].first))

    hop_wait_subtests
  end

  label def wait_subtests
    reap

    if children_idle
      if frame["test_reboot"]
        hop_test_reboot
      else
        hop_destroy_vms
      end
    end

    donate
  end

  label def test_reboot
    host.incr_reboot
    hop_wait_reboot
  end

  label def wait_reboot
    st = host.strand

    if st.label == "wait" && st.semaphores.empty?
      # Run VM tests again, but avoid rebooting again
      current_frame = strand.stack.first
      current_frame["test_reboot"] = false
      strand.modified!(:stack)
      strand.save_changes
      hop_wait_children_ready
    end

    nap 30
  end

  label def destroy_vms
    frame["vms"].each { |vm_id|
      Vm[vm_id].incr_destroy
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

    hop_finish if children_idle

    donate
  end

  label def finish
    Project[frame["project_id"]].destroy
    pop "VmGroup tests finished!"
  end

  def children_idle
    active_children = strand.children_dataset.where(Sequel.~(label: "wait"))
    active_semaphores = strand.children_dataset.join(:semaphore, strand_id: :id)

    active_children.count == 0 and active_semaphores.count == 0
  end

  def host
    vm_id = frame["vms"].first
    Vm[vm_id].vm_host
  end
end
