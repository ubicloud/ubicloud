# frozen_string_literal: true

require "net/ssh"

class Prog::Test::VmGroup < Prog::Test::Base
  def self.assemble(storage_encrypted: true, test_reboot: true)
    Strand.create_with_id(
      prog: "Test::VmGroup",
      label: "start",
      stack: [{
        "storage_encrypted" => storage_encrypted,
        "test_reboot" => test_reboot,
        "vms" => []
      }]
    )
  end

  label def start
    hop_setup_vms
  end

  label def setup_vms
    project = Project.create_with_id(name: "project 1")
    project.associate_with_project(project)

    subnet1_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-first-subnet", location: "hetzner-hel1"
    )

    subnet2_s = Prog::Vnet::SubnetNexus.assemble(
      project.id, name: "the-second-subnet", location: "hetzner-hel1"
    )

    storage_encrypted = frame.fetch("storage_encrypted", true)

    vm1_s = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi", project.id,
      private_subnet_id: subnet1_s.id,
      storage_volumes: [
        {encrypted: storage_encrypted, skip_sync: true},
        {encrypted: storage_encrypted, size_gib: 5}
      ],
      boot_image: Option::BootImages.map { _1.name }.sample,
      enable_ip4: true
    )

    vm2_s = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi", project.id,
      private_subnet_id: subnet1_s.id,
      storage_volumes: [{encrypted: storage_encrypted, skip_sync: false}],
      boot_image: Option::BootImages.map { _1.name }.sample,
      enable_ip4: true
    )

    vm3_s = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi", project.id,
      private_subnet_id: subnet2_s.id,
      storage_volumes: [{encrypted: storage_encrypted, skip_sync: false}],
      boot_image: Option::BootImages.map { _1.name }.sample,
      enable_ip4: true
    )

    update_stack({
      "vms" => [vm1_s.id, vm2_s.id, vm3_s.id],
      "subnets" => [subnet1_s.id, subnet2_s.id],
      "project_id" => project.id
    })

    hop_wait_vms
  end

  label def wait_vms
    nap 10 if frame["vms"].any? { Vm[_1].display_state != "running" }
    hop_verify_vms
  end

  label def verify_vms
    if retval&.dig("msg") == "Verified VM!"
      hop_verify_firewall_rules
    end

    push Prog::Test::Vm, {subject_id: frame["vms"].first}
  end

  label def verify_firewall_rules
    if retval&.dig("msg") == "Verified Firewall Rules!"
      if frame["test_reboot"]
        hop_test_reboot
      else
        hop_destroy_resources
      end
    end

    push Prog::Test::FirewallRules, {subject_id: PrivateSubnet[frame["subnets"].first].firewalls.first.id}
  end

  label def test_reboot
    vm_host.incr_reboot
    hop_wait_reboot
  end

  label def wait_reboot
    if vm_host.strand.label == "wait" && vm_host.strand.semaphores.empty?
      # Run VM tests again, but avoid rebooting again
      update_stack({"test_reboot" => false})
      hop_verify_vms
    end

    nap 20
  end

  label def destroy_resources
    frame["vms"].each { Vm[_1].incr_destroy }
    frame["subnets"].each { PrivateSubnet[_1].incr_destroy }

    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    unless frame["vms"].all? { Vm[_1].nil? } && frame["subnets"].all? { PrivateSubnet[_1].nil? }
      nap 5
    end

    hop_finish
  end

  label def finish
    Project[frame["project_id"]].destroy
    pop "VmGroup tests finished!"
  end

  label def failed
    nap 15
  end

  def vm_host
    @vm_host ||= Vm[frame["vms"].first].vm_host
  end
end
