# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../../lib/gcp_lro"

class Prog::Vm::Gcp::Nexus < Prog::Base
  include GcpLro

  subject_is :vm

  def before_destroy
    register_deadline(nil, 5 * 60)
    vm.active_billing_records.each(&:finalize)
  end

  label def start
    register_deadline("wait", 10 * 60)
    nap 5 unless nic.private_subnet.strand.label == "wait"
    nap 1 unless nic.strand.label == "wait"

    public_keys = vm.sshable.keys.map(&:public_key).join("\n")
    user_data = <<~STARTUP
      #!/bin/bash
      custom_user="#{vm.unix_user}"
      if [ ! -d /home/$custom_user ]; then
        adduser $custom_user --disabled-password --gecos ""
        usermod -aG sudo $custom_user
        echo "$custom_user ALL=(ALL:ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/$custom_user
        mkdir -p /home/$custom_user/.ssh
        chown -R $custom_user:$custom_user /home/$custom_user/.ssh
        chmod 700 /home/$custom_user/.ssh
      fi
      echo '#{public_keys}' > /home/$custom_user/.ssh/authorized_keys
      chown $custom_user:$custom_user /home/$custom_user/.ssh/authorized_keys
      chmod 600 /home/$custom_user/.ssh/authorized_keys
    STARTUP

    boot_disk_size = vm.vm_storage_volumes_dataset.where(boot: true).get(:size_gib) || 20

    disks = [
      Google::Cloud::Compute::V1::AttachedDisk.new(
        auto_delete: true,
        boot: true,
        initialize_params: Google::Cloud::Compute::V1::AttachedDiskInitializeParams.new(
          source_image: gce_source_image,
          disk_size_gb: boot_disk_size
        )
      )
    ]

    # LSSD machine types include bundled local NVMe SSDs; only attach
    # explicit persistent data disks for non-LSSD types.
    unless uses_local_ssd?
      vm.vm_storage_volumes.select { !it.boot }.each do |vol|
        disks << Google::Cloud::Compute::V1::AttachedDisk.new(
          auto_delete: true,
          boot: false,
          initialize_params: Google::Cloud::Compute::V1::AttachedDiskInitializeParams.new(
            disk_size_gb: vol.size_gib,
            disk_type: "zones/#{gcp_zone}/diskTypes/pd-ssd"
          )
        )
      end
    end

    gcp_res = nic.nic_gcp_resource
    instance_resource = Google::Cloud::Compute::V1::Instance.new(
      name: vm.name,
      machine_type: "zones/#{gcp_zone}/machineTypes/#{gce_machine_type}",
      disks:,
      network_interfaces: [
        Google::Cloud::Compute::V1::NetworkInterface.new(
          network: "projects/#{gcp_project_id}/global/networks/#{gcp_res.network_name}",
          subnetwork: "projects/#{gcp_project_id}/regions/#{gcp_region}/subnetworks/#{gcp_res.subnet_name}",
          network_i_p: nic.private_ipv4.network.to_s,
          stack_type: "IPV4_IPV6",
          access_configs: [
            Google::Cloud::Compute::V1::AccessConfig.new(
              name: "External NAT",
              type: "ONE_TO_ONE_NAT",
              network_tier: "STANDARD",
              nat_i_p: gcp_res.static_ip
            )
          ],
          ipv6_access_configs: [
            Google::Cloud::Compute::V1::AccessConfig.new(
              name: "External IPv6",
              type: "DIRECT_IPV6",
              network_tier: "PREMIUM"
            )
          ]
        )
      ],
      metadata: Google::Cloud::Compute::V1::Metadata.new(
        items: [
          Google::Cloud::Compute::V1::Items.new(
            key: "ssh-keys",
            value: "#{vm.unix_user}:#{public_keys}"
          ),
          Google::Cloud::Compute::V1::Items.new(
            key: "startup-script",
            value: user_data
          )
        ]
      )
    )

    # Persist zone suffix in VM strand so it survives NIC destruction
    zone_suffix = nic.strand.stack.dig(0, "gcp_zone_suffix") || "a"
    strand.stack.first["gcp_zone_suffix"] = zone_suffix
    strand.modified!(:stack)
    strand.save_changes

    begin
      op = compute_client.insert(
        project: gcp_project_id,
        zone: gcp_zone,
        instance_resource:
      )
      save_gcp_op(op.name, "zone", gcp_zone)
    rescue Google::Cloud::AlreadyExistsError
      # Instance already exists from a prior attempt — proceed to wait
    rescue Google::Cloud::ResourceExhaustedError => e
      retry_zone_capacity(e.message)
    rescue Google::Cloud::UnavailableError => e
      retry_zone_capacity(e.message)
    end

    hop_wait_create_op
  end

  label def wait_create_op
    unless frame["gcp_op_name"]
      hop_start if frame["zone_retries"]
      hop_wait_instance_created
    end

    op = poll_gcp_op
    unless op.status == :DONE
      nap 5
    end
    if op_error?(op)
      error_code = op_error_code(op)
      if %w[ZONE_RESOURCE_POOL_EXHAUSTED QUOTA_EXCEEDED].include?(error_code)
        clear_gcp_op
        retry_zone_capacity("GCE operation error: #{error_code}")
      end
      raise "GCE instance creation failed: #{op_error_message(op)}"
    end
    clear_gcp_op
    hop_wait_instance_created
  end

  label def wait_instance_created
    instance = compute_client.get(
      project: gcp_project_id,
      zone: gcp_zone,
      instance: vm.name
    )

    case instance.status
    when "RUNNING"
      # proceed
    when "TERMINATED", "SUSPENDED"
      raise "GCE instance entered terminal state: #{instance.status}"
    else
      nap 5
    end

    ni = instance.network_interfaces.first
    public_ipv4 = ni && ni.access_configs.first&.nat_i_p
    public_ipv6 = ni&.ipv6_access_configs&.first&.external_ipv6

    if public_ipv4
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4)
      vm.sshable.update(host: public_ipv4)
    end

    vm.update(cores: vm.vcpus / 2, allocated_at: Time.now, ephemeral_net6: public_ipv6)

    vm.incr_update_firewall_rules
    hop_wait_sshable
  end

  label def wait_sshable
    if retval&.dig("msg") == "firewall rule is added"
      decr_update_firewall_rules
    end

    when_update_firewall_rules_set? do
      push vm.update_firewall_rules_prog, {}, :update_firewall_rules
    end

    addr = vm.ip4
    hop_create_billing_record unless addr

    begin
      Socket.tcp(addr.to_s, 22, connect_timeout: 1) {}
    rescue SystemCallError
      nap 1
    end

    hop_create_billing_record
  end

  label def create_billing_record
    vm.update(display_state: "running", provisioned_at: Time.now)

    Clog.emit("vm provisioned", [vm, {provision: {vm_ubid: vm.ubid, duration: (Time.now - vm.allocated_at).round(3)}}])

    project = vm.project
    hop_wait unless project.billable

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus
    )

    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      register_deadline("wait", 5 * 60)
      hop_update_firewall_rules
    end

    nap 6 * 60 * 60
  end

  label def update_firewall_rules
    if retval&.dig("msg") == "firewall rule is added"
      hop_wait
    end

    decr_update_firewall_rules
    push vm.update_firewall_rules_prog, {}, :update_firewall_rules
  end

  label def prevent_destroy
    register_deadline("destroy", 24 * 60 * 60)
    nap 30
  end

  label def destroy
    decr_destroy

    when_prevent_destroy_set? do
      Clog.emit("Destroy prevented by the semaphore")
      hop_prevent_destroy
    end

    vm.update(display_state: "deleting")

    # Clean up per-VM firewall policy rules
    cleanup_vm_policy_rules

    begin
      op = compute_client.delete(
        project: gcp_project_id,
        zone: gcp_zone,
        instance: vm.name
      )
      save_gcp_op(op.name, "zone", gcp_zone)
      hop_wait_destroy_op
    rescue Google::Cloud::NotFoundError
    end

    hop_finalize_destroy
  end

  label def wait_destroy_op
    op = poll_gcp_op
    unless op.status == :DONE
      nap 5
    end
    clear_gcp_op
    hop_finalize_destroy
  end

  label def finalize_destroy
    if nic
      nic.update(vm_id: nil)
      nic.incr_destroy
    end
    vm.destroy
    pop "vm destroyed"
  end

  private

  def nic
    @nic ||= vm.nic
  end

  def credential
    @credential ||= vm.location.location_credential
  end

  def compute_client
    @compute_client ||= credential.compute_client
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_zone
    @gcp_zone ||= begin
      region = vm.location.name.delete_prefix("gcp-")
      zone_suffix = strand.stack.dig(0, "gcp_zone_suffix") || (nic && nic.strand.stack.dig(0, "gcp_zone_suffix")) || "a"
      "#{region}-#{zone_suffix}"
    end
  end

  def gcp_region
    @gcp_region ||= vm.location.name.delete_prefix("gcp-")
  end

  GCE_LSSD_VCPUS = {
    "c4a" => [4, 8, 16, 32, 48, 64, 72].freeze,
    "c3" => [4, 8, 22, 44, 88, 176].freeze,
    "c3d" => [8, 16, 30, 60, 90, 180, 360].freeze
  }.freeze

  def gce_machine_type
    case vm.family
    when "burstable"
      (vm.vcpus <= 1) ? "e2-small" : "e2-medium"
    when *Option::GCP_FAMILY_OPTIONS
      prefix = vm.family.split("-")[0] # c4a, c3, c3d
      valid_vcpus = GCE_LSSD_VCPUS[prefix]
      gce_vcpus = valid_vcpus.find { |n| n >= vm.vcpus } || valid_vcpus.last
      "#{vm.family}-#{gce_vcpus}-lssd"
    else
      vcpus = [vm.vcpus, 2].max
      if vcpus <= 2
        "e2-standard-2"
      else
        gce_vcpus = GCE_LSSD_VCPUS["c3d"].find { |n| n >= vcpus } || 360
        "c3d-standard-#{gce_vcpus}-lssd"
      end
    end
  end

  def uses_local_ssd?
    gce_machine_type.end_with?("-lssd")
  end

  GCE_BOOT_IMAGE_FAMILIES = {
    "ubuntu-noble" => {project: "ubuntu-os-cloud", family: "ubuntu-2404-lts-amd64", family_arm64: "ubuntu-2404-lts-arm64"},
    "ubuntu-jammy" => {project: "ubuntu-os-cloud", family: "ubuntu-2204-lts", family_arm64: "ubuntu-2204-lts-arm64"}
  }.freeze

  def gce_source_image
    return vm.boot_image if vm.boot_image&.start_with?("projects/")

    entry = GCE_BOOT_IMAGE_FAMILIES[vm.boot_image]
    raise "Unknown boot image '#{vm.boot_image}' — expected a projects/* path or one of: #{GCE_BOOT_IMAGE_FAMILIES.keys.join(", ")}" unless entry

    family = (vm.arch == "arm64") ? entry[:family_arm64] : entry[:family]
    "projects/#{entry[:project]}/global/images/family/#{family}"
  end

  def retry_zone_capacity(error_message)
    retries = (frame["zone_retries"] || 0) + 1
    if retries >= 5
      raise "GCE instance creation failed after #{retries} zone retries: #{error_message}"
    end
    Clog.emit("GCE zone capacity exhausted", {zone_exhausted: {zone: gcp_zone, retries:, error: error_message}})
    update_stack({"zone_retries" => retries})
    nap 30
  end

  # --- Cleanup ---

  def cleanup_vm_policy_rules
    policy_name = Prog::Vnet::Gcp::SubnetNexus.vpc_name(vm.location)

    begin
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: policy_name
      )
    rescue Google::Cloud::NotFoundError
      return # Policy already deleted
    end

    vm_ip = nic&.private_ipv4&.network&.to_s
    return unless vm_ip

    vm_dest = "#{vm_ip}/32"

    (policy.rules || []).each do |rule|
      next unless rule.direction == "INGRESS" && rule.action == "allow"
      next unless rule.match&.dest_ip_ranges&.include?(vm_dest)
      credential.network_firewall_policies_client.remove_rule(
        project: gcp_project_id,
        firewall_policy: policy_name,
        priority: rule.priority
      )
    rescue Google::Cloud::NotFoundError
      # Already deleted
    end
  rescue Google::Cloud::Error => e
    Clog.emit("Failed to clean up GCE firewall resources", {gcp_firewall_cleanup_error: {vm_name: vm.name, error: e.message}})
  end
end
