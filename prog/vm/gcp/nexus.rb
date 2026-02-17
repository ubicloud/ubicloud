# frozen_string_literal: true

require "google/cloud/compute/v1"

class Prog::Vm::Gcp::Nexus < Prog::Base
  subject_is :vm

  def before_destroy
    register_deadline(nil, 5 * 60)
    vm.active_billing_records.each(&:finalize)
  end

  label def start
    register_deadline("wait", 10 * 60)
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

    instance_resource = Google::Cloud::Compute::V1::Instance.new(
      name: vm.name,
      machine_type: "zones/#{gcp_zone}/machineTypes/#{gce_machine_type}",
      disks:,
      network_interfaces: [
        Google::Cloud::Compute::V1::NetworkInterface.new(
          network: "global/networks/default",
          access_configs: [
            Google::Cloud::Compute::V1::AccessConfig.new(
              name: "External NAT",
              type: "ONE_TO_ONE_NAT",
              network_tier: "STANDARD"
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
      ),
      tags: Google::Cloud::Compute::V1::Tags.new(
        items: ["ubicloud-vm", "allow-ssh"]
      )
    )

    op = compute_client.insert(
      project: gcp_project_id,
      zone: gcp_zone,
      instance_resource:
    )
    op.wait_until_done!
    raise "GCE instance creation failed: #{op.results.error}" if op.error?

    hop_wait_instance_created
  end

  label def wait_instance_created
    instance = compute_client.get(
      project: gcp_project_id,
      zone: gcp_zone,
      instance: vm.name
    )

    unless instance.status == "RUNNING"
      nap 5
    end

    ni = instance.network_interfaces.first
    public_ipv4 = ni && ni.access_configs.first&.nat_i_p

    if public_ipv4
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4)
      vm.sshable.update(host: public_ipv4)
    end

    vm.update(cores: vm.vcpus / 2, allocated_at: Time.now)

    hop_wait_sshable
  end

  label def wait_sshable
    unless vm.update_firewall_rules_set?
      vm.incr_update_firewall_rules
      nap 6
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

    begin
      op = compute_client.delete(
        project: gcp_project_id,
        zone: gcp_zone,
        instance: vm.name
      )
      op.wait_until_done!
    rescue Google::Cloud::NotFoundError
    end

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
    @credential ||= vm.location.location_credential_gcp
  end

  def compute_client
    @compute_client ||= credential.compute_client
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_zone
    @gcp_zone ||= "#{vm.location.name.delete_prefix("gcp-")}-a"
  end

  def gce_machine_type
    vcpus = vm.vcpus
    "e2-standard-#{(vcpus < 2) ? 2 : vcpus}"
  end

  def gce_source_image
    "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
  end
end
