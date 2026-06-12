# frozen_string_literal: true

class Prog::Vm::Gcp::Nexus < Prog::Base
  include GcpLro

  subject_is :vm
  frame_reader :unsupported_azs, :storage_volumes
  frame_accessor :retry_zone_delay, :gcp_zone_suffix, :exclude_zones

  def before_destroy
    register_deadline(nil, 5 * 60)
    vm.active_billing_records.each(&:finalize)
  end

  label def start
    if (delay = retry_zone_delay)
      self.retry_zone_delay = nil
      nap delay
    end
    register_deadline("wait", 10 * 60)
    nap 5 unless user_nic.private_subnet.strand.label == "wait"
    nap 1 unless user_nic.strand.label == "wait"

    # Zone selection is a VM concern. Pick a zone on first entry, then
    # honour the value already set by retry_zone_capacity on later entries.
    unless strand.stack.first.key?("gcp_zone_suffix")
      excluded = (exclude_zones || [].freeze) + (unsupported_azs || [].freeze)
      available = gcp_az_suffixes - excluded
      location_az = location_az_for(available.sample || gcp_az_suffixes.sample)
      VmGcpResource.create_with_id(vm, location_az_id: location_az.id) unless vm.vm_gcp_resource
      self.gcp_zone_suffix = location_az.az
    end

    user_data = NetSsh.command(<<~STARTUP, custom_user: vm.unix_user, public_keys: vm.sshable.keys.map(&:public_key).join("\n"))
      #!/bin/bash
      if [ ! -d /home/:custom_user ]; then
        adduser :custom_user --disabled-password --gecos ""
        usermod -aG sudo :custom_user
        echo :custom_user' ALL=(ALL:ALL) NOPASSWD:ALL' | tee /etc/sudoers.d/:custom_user
        mkdir -p /home/:custom_user/.ssh
        chown -R :custom_user::custom_user /home/:custom_user/.ssh
        chmod 700 /home/:custom_user/.ssh
      fi
      echo :public_keys > /home/:custom_user/.ssh/authorized_keys
      chown :custom_user::custom_user /home/:custom_user/.ssh/authorized_keys
      chmod 600 /home/:custom_user/.ssh/authorized_keys
    STARTUP

    disks = vm.vm_storage_volumes_dataset.order(:disk_index).map do |vol|
      if vol.boot
        Google::Cloud::Compute::V1::AttachedDisk.new(
          auto_delete: true,
          boot: true,
          initialize_params: Google::Cloud::Compute::V1::AttachedDiskInitializeParams.new(
            source_image: gce_source_image,
            disk_size_gb: vol.size_gib,
          ),
        )
      elsif (spec = network_volume_specs[vol.disk_index])
        # Persistent disk created inline with the instance: auto_delete rides
        # instance delete, and GCE attaches an already-existing disk of the
        # same name instead of failing, making insert retries idempotent.
        # disk_name is recorded before insert so wal_volume/device_path
        # resolve from first observation; explicit device_name surfaces the
        # disk at /dev/disk/by-id/google-persistent-disk-N via google_nvme_id
        # udev. 3000 IOPS / 140 MiB/s is the free hyperdisk-balanced baseline.
        vol.update(provider_volume_id: "#{vm.name}-#{vol.disk_index}") unless vol.provider_volume_id
        Google::Cloud::Compute::V1::AttachedDisk.new(
          auto_delete: true,
          device_name: "persistent-disk-#{vol.disk_index}",
          initialize_params: Google::Cloud::Compute::V1::AttachedDiskInitializeParams.new(
            disk_name: vol.provider_volume_id,
            disk_type: "zones/#{gcp_zone}/diskTypes/#{spec["network_volume_type"]}",
            disk_size_gb: vol.size_gib,
            provisioned_iops: 3000,
            provisioned_throughput: 140,
          ),
        )
      else
        local_ssd_disk
      end
    end

    # -lssd machine types demand their full local SSD complement declared at
    # insert. With network volumes the rows map to persistent disks, so
    # synthesize the remaining local SSDs (bcache cache devices, matched by
    # instance_store_device_glob) without VmStorageVolume rows, mirroring
    # AWS instance-store NVMe
    if network_volume_specs.any?
      (local_ssd_count - disks.count { it.type == "SCRATCH" }).times { disks << local_ssd_disk }
    end

    gcp_res = user_nic.nic_gcp_resource
    instance_resource = Google::Cloud::Compute::V1::Instance.new(
      name: vm.name,
      machine_type: "zones/#{gcp_zone}/machineTypes/#{gce_machine_type}",
      labels: {"ubicloud" => Config.provider_resource_tag_value},
      disks:,
      network_interfaces: [
        Google::Cloud::Compute::V1::NetworkInterface.new(
          network: "projects/#{gcp_project_id}/global/networks/#{gcp_res.vpc_name}",
          subnetwork: "projects/#{gcp_project_id}/regions/#{gcp_region}/subnetworks/#{gcp_res.subnet_name}",
          network_i_p: user_nic.private_ipv4.network.to_s,
          stack_type: "IPV4_IPV6",
          access_configs: [
            Google::Cloud::Compute::V1::AccessConfig.new(
              name: "External NAT",
              type: "ONE_TO_ONE_NAT",
              network_tier: "STANDARD",
              nat_i_p: gcp_res.static_ip.to_s,
            ),
          ],
          ipv6_access_configs: [
            Google::Cloud::Compute::V1::AccessConfig.new(
              name: "External IPv6",
              type: "DIRECT_IPV6",
              network_tier: "PREMIUM",
            ),
          ],
        ),
      ],
      metadata: Google::Cloud::Compute::V1::Metadata.new(
        items: [
          Google::Cloud::Compute::V1::Items.new(
            key: "startup-script",
            value: user_data,
          ),
        ],
      ),
    )

    begin
      op = compute_client.insert(
        project: gcp_project_id,
        zone: gcp_zone,
        instance_resource:,
      )
      save_gcp_op("create_vm", op_name: op.name, scope: "zone", scope_value: gcp_zone)
      hop_wait_create_op
    rescue Google::Cloud::AlreadyExistsError
      # Instance already exists from a prior attempt, skip the LRO wait
      hop_wait_instance_created
    rescue Google::Cloud::ResourceExhaustedError, Google::Cloud::UnavailableError => e
      retry_zone_capacity(e.message)
    rescue Google::Cloud::InvalidArgumentError => e
      raise unless e.message.include?("does not exist in zone")
      retry_zone_capacity(e.message)
    end
  end

  label def wait_create_op
    poll_and_clear_gcp_op("create_vm") do |op|
      error_code = op_error_code(op)
      if %w[ZONE_RESOURCE_POOL_EXHAUSTED ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS QUOTA_EXCEEDED INTERNAL_ERROR].freeze.include?(error_code)
        clear_gcp_op("create_vm")
        # Stash the backoff delay; #start naps it off before retrying (nap here would re-enter wait_create_op).
        self.retry_zone_delay = bump_excluded_zone("GCE operation error: #{error_code}")
        hop_start
      end
      raise "GCE instance creation failed: #{op_error_message(op)}"
    end
    hop_wait_instance_created
  end

  label def wait_instance_created
    instance = compute_client.get(
      project: gcp_project_id,
      zone: gcp_zone,
      instance: vm.name,
    )

    case instance.status
    when "RUNNING"
      # name@zone encoding: e2e cleanup grep splits the pair so it can pass
      # both --zone and the instance name to `gcloud compute instances
      # delete`.
      Clog.emit("GCP instance created", {gcp_instance_created: "#{vm.name}@#{gcp_zone}"})
    when "TERMINATED", "SUSPENDED"
      Prog::PageNexus.assemble(
        "GCE VM #{vm.ubid} entered terminal state #{instance.status} during provisioning",
        ["GceProvisionTerminal", vm.ubid, instance.status],
        vm.ubid,
      )
      unregister_deadline("wait")
      nap 6 * 60 * 60
    else
      nap 5
    end

    ni = instance.network_interfaces.first
    public_ipv4 = ni&.access_configs&.first&.nat_i_p
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
    time = Time.now
    vm.update(display_state: "running", provisioned_at: time)

    Clog.emit("vm provisioned", [vm, {provision: {vm_ubid: vm.ubid, duration: (time - vm.allocated_at).round(3)}}])

    project = vm.project
    hop_wait unless project.billable

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus,
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

    begin
      op = compute_client.delete(
        project: gcp_project_id,
        zone: gcp_zone,
        instance: vm.name,
      )
      save_gcp_op("delete_vm", op_name: op.name, scope: "zone", scope_value: gcp_zone)
      hop_wait_destroy_op
    rescue Google::Cloud::NotFoundError
      nil
    end

    hop_finalize_destroy
  end

  label def wait_destroy_op
    op = poll_gcp_op("delete_vm")
    unless op.status == :DONE
      nap 5
    end
    raise "GCE instance deletion failed: #{op_error_message(op)}" if op_error?(op)
    clear_gcp_op("delete_vm")
    hop_finalize_destroy
  end

  label def finalize_destroy
    if user_nic
      user_nic.update(vm_id: nil)
      user_nic.incr_destroy
    end
    vm.destroy
    pop "vm destroyed"
  end

  private

  def user_nic
    @user_nic ||= vm.user_nic
  end

  def credential
    @credential ||= vm.location.location_credential_gcp
  end

  def compute_client
    @compute_client ||= credential.compute_client
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_zone
    @gcp_zone ||= "#{gcp_region}-#{gcp_zone_suffix}"
  end

  undef_method :gcp_zone_suffix
  def gcp_zone_suffix
    strand.stack.dig(0, "gcp_zone_suffix") || gcp_az_suffixes.sample
  end

  def gcp_region
    @gcp_region ||= vm.location.name.delete_prefix("gcp-")
  end

  def gce_machine_type
    @gce_machine_type ||= Option.gcp_instance_type_name(vm.family, vm.vcpus)
  end

  # network_volume_type marks a volume spec for creation as a persistent disk
  # of that type (hyperdisk-balanced); keyed by disk_index, replaying the
  # split arithmetic of Prog::Vm::Nexus.assemble
  def network_volume_specs
    @network_volume_specs ||= begin
      specs = {}
      disk_index = 0
      storage_volumes.each do |volume|
        specs[disk_index] = volume if volume["network_volume_type"]
        disk_index += (volume["boot"] || volume["network_volume_type"]) ? 1 : (volume["size_gib"]/375r).ceil
      end
      specs
    end
  end

  # Local NVMe SSD. GCE 3rd-gen `-lssd` machine types require local SSDs to
  # be declared explicitly at instance create, one 375 GiB LSSD each. Guest
  # paths resolve via /dev/disk/by-id/google-local-nvme-ssd-N based on NVMe
  # attach order, matching VmStorageVolume::Gcp#gcp_device_path
  def local_ssd_disk
    Google::Cloud::Compute::V1::AttachedDisk.new(
      type: "SCRATCH",
      auto_delete: true,
      interface: "NVME",
      initialize_params: Google::Cloud::Compute::V1::AttachedDiskInitializeParams.new(
        disk_type: "zones/#{gcp_zone}/diskTypes/local-ssd",
        disk_size_gb: 375,
      ),
    )
  end

  def local_ssd_count
    Option::GCP_STORAGE_SIZE_OPTIONS[vm.family][vm.vcpus].max / 375
  end

  GCE_BOOT_IMAGE_FAMILIES = {
    "ubuntu-noble" => {project: "ubuntu-os-cloud", family: "ubuntu-2404-lts-ARCH"},
    "ubuntu-jammy" => {project: "ubuntu-os-cloud", family: "ubuntu-2204-lts-ARCH"},
  }.freeze

  def gce_source_image
    return vm.boot_image if vm.boot_image.start_with?("projects/")

    entry = GCE_BOOT_IMAGE_FAMILIES[vm.boot_image]
    raise "Unknown boot image '#{vm.boot_image}'. Expected a projects/* path or one of: #{GCE_BOOT_IMAGE_FAMILIES.keys.join(", ")}" unless entry

    gce_arch = (vm.arch == "arm64") ? "arm64" : "amd64"
    family = entry[:family].sub("ARCH", gce_arch)
    "projects/#{entry[:project]}/global/images/family/#{family}"
  end

  def retry_zone_capacity(error_message)
    nap bump_excluded_zone(error_message)
  end

  def bump_excluded_zone(error_message)
    excluded = (exclude_zones || [].freeze) + [gcp_zone_suffix]
    available = gcp_az_suffixes - excluded

    if available.empty?
      Clog.emit("GCE zone retry exhausted, resetting exclusions",
        {zone_retry: {failed_zone: gcp_zone, excluded:,
                      error: error_message}})
      excluded = []
      available = gcp_az_suffixes
    else
      Clog.emit("GCE zone retry",
        {zone_retry: {failed_zone: gcp_zone, excluded:,
                      remaining: available, error: error_message}})
    end

    new_suffix = available.sample
    # Clear memoized zone so the next iteration uses the new suffix
    @gcp_zone = nil
    self.gcp_zone_suffix = new_suffix
    self.exclude_zones = excluded
    vm.reload.vm_gcp_resource.update(location_az_id: location_az_for(new_suffix).id)
    # 5 minutes: all zones exhausted, exclusions reset. Wait for capacity to free up.
    # 5 seconds: still have untried zones. Move on to the next one quickly.
    (available.length == gcp_az_suffixes.length) ? 5 * 60 : 5
  end

  def gcp_az_suffixes
    @gcp_az_suffixes ||= vm.location.azs.map(&:az)
  end

  def location_az_for(suffix)
    vm.location.location_azs_dataset.first(az: suffix) ||
      raise("no location_az row for gcp-#{gcp_region}/#{suffix}")
  end
end
