# frozen_string_literal: true

require_relative "../../lib/net_ssh"

class Prog::Test::VmGroup < Prog::Test::Base
  def self.assemble(boot_images:, provider: "metal", storage_encrypted: true, test_reboot: true, test_slices: false, verify_host_capacity: true)
    Strand.create(
      prog: "Test::VmGroup",
      label: "start",
      stack: [{
        "provider" => provider,
        "storage_encrypted" => storage_encrypted,
        "test_reboot" => test_reboot,
        "first_boot" => true,
        "test_slices" => test_slices,
        "vms" => [],
        "boot_images" => boot_images,
        "verify_host_capacity" => verify_host_capacity
      }]
    )
  end

  label def start
    hop_setup_vms
  end

  label def setup_vms
    project = Project.create(name: "project-1")
    provider = frame.fetch("provider", "metal")
    test_slices = frame.fetch("test_slices")

    location_id, size_options, arch = if provider == "aws"
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      unless LocationCredential[location.id]
        LocationCredential.create_with_id(location.id, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      end
      family = "m8gd"
      vcpus = 2
      [location.id, [Option.aws_instance_type_name(family, vcpus)], "arm64"]
    elsif provider == "gcp"
      location = Location[provider: "gcp", project_id: nil]
      unless LocationCredential[location.id]
        LocationCredential.create_with_id(location.id,
          credentials_json: Config.e2e_gcp_credentials_json,
          project_id: Config.e2e_gcp_project_id,
          service_account_email: Config.e2e_gcp_service_account_email)
      end
      [location.id, ["standard-2"], "x64"]
    else
      [Location::HETZNER_FSN1_ID, test_slices ? ["standard-2", "burstable-1"] : ["standard-2"], "x64"]
    end

    subnets = Array.new(2) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "subnet-#{it}", location_id:) }
    encrypted = frame.fetch("storage_encrypted", true)
    boot_images = frame.fetch("boot_images")
    storage_options = if provider == "metal"
      [
        [{encrypted:, skip_sync: true}, {encrypted:, size_gib: 5}],
        [{encrypted:, skip_sync: false, max_read_mbytes_per_sec: 200, max_write_mbytes_per_sec: 150}],
        [{encrypted:, skip_sync: false}]
      ]
    else
      [[{}]]
    end
    # Minimum 3 VMs: firewall + connected subnet tests need 2 VMs in one subnet, 1 in another
    vm_count = [boot_images.size, storage_options.size, size_options.size, 3].max
    vms = Array.new(vm_count) do |index|
      Prog::Vm::Nexus.assemble_with_sshable(project.id,
        sshable_unix_user: "ubi",
        size: size_options[index % size_options.size],
        location_id:,
        arch:,
        private_subnet_id: subnets[index % subnets.size].id,
        storage_volumes: storage_options[index % storage_options.size],
        boot_image: boot_images[index % boot_images.size],
        enable_ip4: true)
    end

    update_stack({
      "vms" => vms.map(&:id),
      "subnets" => subnets.map(&:id),
      "project_id" => project.id
    })

    hop_wait_vms
  end

  label def wait_vms
    nap 10 if frame["vms"].any? { Vm[it].display_state != "running" }
    hop_verify_vms
  end

  label def verify_vms
    frame["vms"].each { bud(Prog::Test::Vm, {subject_id: it, first_boot: frame["first_boot"]}) }
    hop_wait_verify_vms
  end

  label def wait_verify_vms
    reap(:verify_host_capacity)
  end

  label def verify_host_capacity
    hop_verify_vm_host_slices if !frame["verify_host_capacity"] || frame["provider"] != "metal"

    vm_cores = vm_host.vms.sum(&:cores)
    slice_cores = vm_host.slices.sum(&:cores)

    fail_test "Host used cores does not match the allocated VMs cores (vm_cores=#{vm_cores}, slice_cores=#{slice_cores}, used_cores=#{vm_host.used_cores})" if vm_cores + slice_cores != vm_host.used_cores

    hop_verify_vm_host_slices
  end

  label def verify_vm_host_slices
    test_slices = frame.fetch("test_slices")

    if !test_slices || frame["provider"] != "metal" || (retval&.dig("msg") == "Verified VM Host Slices!")
      hop_verify_storage_rpc
    end

    slices = frame["vms"].map { Vm[it].vm_host_slice&.id }.reject(&:nil?)
    push Prog::Test::VmHostSlices, {"slices" => slices}
  end

  label def verify_storage_rpc
    if frame["provider"] == "metal"
      frame["vms"].each do |id|
        vm = Vm[id]
        command = {command: "version"}.to_json
        response = vm_host.sshable.cmd_json("sudo nc -U /var/storage/:inhost_name/0/rpc.sock -q 0", inhost_name: vm.inhost_name, stdin: command)
        expected_version = Config.vhost_block_backend_version.delete_prefix("v")
        fail_test "Failed to get vhost-block-backend version for VM #{vm.id} using RPC" unless response["version"] == expected_version
      end
    end

    hop_verify_firewall_rules
  end

  label def verify_firewall_rules
    if retval&.dig("msg") == "Verified Firewall Rules!"
      hop_verify_connected_subnets
    end

    push Prog::Test::FirewallRules, {subject_id: PrivateSubnet[frame["subnets"].first].firewalls.first.id}
  end

  label def verify_connected_subnets
    if retval&.dig("msg") == "Verified Connected Subnets!"
      if frame["test_reboot"] && frame["first_boot"] && frame["provider"] == "metal"
        hop_test_reboot
      else
        hop_destroy_resources
      end
    end

    # AWS and GCP use separate VPCs per subnet — no cross-VPC private routing without peering
    hop_destroy_resources if frame["provider"] != "metal"

    ps1, ps2 = frame["subnets"].map { PrivateSubnet[it] }
    push Prog::Test::ConnectedSubnets, {subnet_id_multiple: ((ps1.vms.count > 1) ? ps1.id : ps2.id), subnet_id_single: ((ps1.vms.count > 1) ? ps2.id : ps1.id)}
  end

  label def test_reboot
    vm_host.incr_reboot
    hop_wait_reboot
  end

  label def wait_reboot
    if vm_host.strand.label == "wait" && vm_host.strand.semaphores.empty?
      # Run VM tests again, but avoid rebooting again
      update_stack({"first_boot" => false})
      hop_verify_vms
    end

    nap 20
  end

  label def destroy_resources
    frame["vms"].each { Vm[it].incr_destroy }
    frame["subnets"].each { PrivateSubnet[it].tap { |ps| ps.firewalls.each { |fw| fw.destroy } }.incr_destroy }

    hop_wait_resources_destroyed
  end

  label def wait_resources_destroyed
    unless frame["vms"].all? { Vm[it].nil? } && frame["subnets"].all? { PrivateSubnet[it].nil? }
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
