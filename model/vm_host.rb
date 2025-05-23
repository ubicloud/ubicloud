# frozen_string_literal: true

require "shellwords"
require_relative "../model"
require_relative "../lib/hosting/apis"
require_relative "../lib/system_parser"

class VmHost < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :sshable, key: :id
  one_to_many :vms
  one_to_many :assigned_subnets, key: :routed_to_host_id, class: :Address
  one_to_one :provider, key: :id, class: :HostProvider
  one_to_many :assigned_host_addresses, key: :host_id, class: :AssignedHostAddress
  one_to_many :spdk_installations, key: :vm_host_id
  one_to_many :vhost_block_backends
  one_to_many :storage_devices, key: :vm_host_id
  one_to_many :pci_devices, key: :vm_host_id
  one_to_many :boot_images, key: :vm_host_id
  one_to_many :slices, class: :VmHostSlice, key: :vm_host_id
  one_to_many :cpus, class: :VmHostCpu, key: :vm_host_id
  many_to_one :location, key: :location_id, class: :Location

  many_to_many :assigned_vm_addresses, join_table: :address, left_key: :routed_to_host_id, right_key: :id, right_primary_key: :address_id, read_only: true

  plugin :association_dependencies, assigned_host_addresses: :destroy, assigned_subnets: :destroy, provider: :destroy, spdk_installations: :destroy, storage_devices: :destroy, pci_devices: :destroy, boot_images: :destroy, slices: :destroy, cpus: :destroy

  plugin ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods
  include MetricsTargetMethods
  semaphore :checkup, :reboot, :hardware_reset, :destroy, :graceful_reboot, :configure_metrics

  def host_prefix
    net6.netmask.prefix_len
  end

  def vm_addresses
    vms.filter_map(&:assigned_vm_address)
  end

  def provider_name
    provider&.provider_name
  end

  # Compute the IPv6 Subnet that can be used to address the host
  # itself, and should not be delegated to any VMs.
  #
  # The default prefix length is 79, so that customers can be given a
  # /80 for their own exclusive use, and paired is the adjacent /80
  # for Clover's use on behalf of that VM.  This leaves 15 bits of
  # entropy relative to the customary /64 allocated to a real device.
  #
  # Offering a /80 to the VM renders nicely in the IPv6 format, as
  # it's 5 * 16, and each delimited part of IPv6 is 16 bits.
  #
  # A /80 is the longest prefix that is divisible by 16 and contains
  # multiple /96 subnets within it.  /96 is of special significance
  # because it contains enough space within it to hold the IPv4
  # address space, i.e. leaving the door open for schemes relying on
  # SIIT translation: https://datatracker.ietf.org/doc/html/rfc7915
  def ip6_reserved_network(prefix = 79)
    # Interpret a nil ip6 address and a not-nil network as there being
    # no network reserved for the host in net6.
    #
    # The reason: some vendors prefer to delegate a network that
    # bypasses neighbor discovery protocol (NDP) that is different
    # than the network customarily assigned to the physical network
    # interface.
    #
    # And on at least one, the network interface *must* respond to
    # neighbor discovery for that customary network/IP in order to be
    # routed the delegated /64.  The two networks have no overlap with
    # one another.  So alas, our ability to auto-configure from the
    # host in such a case is limited.
    return nil if ip6.nil? && !net6.nil?
    fail "BUG: host prefix must be is shorter than reserved prefix" unless host_prefix < prefix

    NetAddr::IPv6Net.new(ip6, NetAddr::Mask128.new(prefix))
  end

  # Generate a random network that is a slice of the host's network
  # for delegation to a VM.
  def ip6_random_vm_network
    prefix = host_prefix + 15
    # We generate 2 bytes of entropy for the lower bits
    # and append them to the host's network. This way,
    # the first X bits are the same as the host's network.
    # And the next 16 bits are random. To achieve that, we shift
    # the random number to the left by (128 - prefix - 1) bits.
    # This way, the random number is placed in the correct position.
    # With a simple example:
    # Let's say we have a /64 network: 0:0:0:0::/64
    # This can be expanded to: 0:0:0:0:0:0:0:0/64
    # With even further expansion: 0000:0000:0000:0000:0000:0000:0000:0000/64
    # Now, we can generate a random number between 2 and 2**16 (65536). This
    # will be our next 2 bytes. Let's say the random number is 5001. In base 16,
    # this is 0x1389.
    # Now, if we shift it by 48 bits (3 octets) as it is in ipv6 addresses:
    # 1389:0:0:0
    # now if we OR it with the host's network:
    # 0:0:0:0:0:0:0:0 | 0:0:0:0:1389:0:0:0  = 0:0:0:0:1389:0:0:0/80
    # We are not done yet, if you realized, we are masking it with 79 not 80.
    # Because this /79 is later split into 2 /80s for internal and external use.
    # Therefore, the network we return is:
    # 2a01:4f9:2b:35a:1388:0:0:0/79
    # and the two /80 networks are:
    # 2a01:4f9:2b:35a:1388:0:0:0/80 and 2a01:4f9:2b:35a:1389:0:0:0/80
    lower_bits = SecureRandom.random_number(2...2**16) << (128 - prefix - 1)

    # Combine it with the higher bits for the host.
    proposal = NetAddr::IPv6Net.new(
      NetAddr::IPv6.new(net6.network.addr | lower_bits), NetAddr::Mask128.new(prefix)
    )

    # :nocov:
    fail "BUG: host should be supernet of randomized subnet" unless net6.rel(proposal) == 1
    # :nocov:

    case (rn = ip6_reserved_network(prefix)) && proposal.network.cmp(rn.network)
    when 0
      # Guard against choosing the host-reserved network for a guest
      # and try again.  Recursion is used here because it's a likely
      # code path, and if there's a bug, it's better to stack overflow
      # rather than loop forever.
      ip6_random_vm_network
    else
      proposal
    end
  end

  def ip4_random_vm_network
    ipv4_ds = DB[:ipv4_address].join(:address, [:cidr]).where(cidr: assigned_subnets_dataset.select(:cidr))

    res = ipv4_ds
      .exclude(assigned_vm_addresses_dataset.where(ip: Sequel[:ipv4_address][:ip]).select(1).exists)
      .order { random.function }
      .first

    return [res.delete(:ip), Address.call(res)] if res

    # we get the available subnets and if the subnet is /32, we eliminate it
    available_subnets = assigned_subnets.select { |a| a.cidr.version == 4 && a.cidr.network.to_s != sshable.host }

    if ipv4_ds.empty? && !available_subnets.empty?
      # In case there is a bug and the ipv4_address table is not populated correctly,
      # we fallback to the previous slow implementation.  After a certain amount of time,
      # if we don't see any of these logs emitted in production, we can remove the fallback
      # and rely on the ipv4_address table being populated.
      Clog.emit("ipv4_address table not populated for ipv4 address range") { {vm_host_id: id} }
    else
      # ipv4_address table populated or there aren't any subnets, no point in
      # doing further work.  This would not correctly handle cases where the ipv4
      # address table is partially populated instead of fully populated.
      return [nil, nil]
    end

    # we eliminate the subnets that are full
    used_subnet = available_subnets.select { |as| as.assigned_vm_addresses.count != 2**(32 - as.cidr.netmask.prefix_len) }.sample

    # not available subnet
    return [nil, nil] unless used_subnet

    rand = SecureRandom.random_number(2**(32 - used_subnet.cidr.netmask.prefix_len)).to_i
    picked_subnet = used_subnet.cidr.nth(rand)
    # we check if the picked subnet is used by one of the vms
    return ip4_random_vm_network if vm_addresses.map { it.ip.to_s }.include?("#{picked_subnet}/32")

    # For Leaseweb, avoid using the very first and the last ips
    if provider_name == "leaseweb"
      subnet_size = 2**(32 - used_subnet.cidr.netmask.prefix_len)
      last_ip = used_subnet.cidr.nth(subnet_size - 1).to_s
      first_ip = used_subnet.cidr.network.to_s
      if picked_subnet.to_s == first_ip.to_s || picked_subnet.to_s == last_ip.to_s
        return ip4_random_vm_network
      end
    end
    [picked_subnet, used_subnet]
  end

  def veth_pair_random_ip4_addr
    addr = NetAddr::IPv4Net.parse("169.254.0.0/16")
    # we get 1 address here and use the next address to assign
    # route for vetho* and vethi* devices. So, we are splitting the local address
    # space to two but only store 1 of them for the existence check.
    # that's why the range is 2 * ((addr.len - 2) / 2)
    selected_addr = NetAddr::IPv4Net.new(addr.nth(2 * SecureRandom.random_number((addr.len - 2) / 2)), NetAddr::Mask32.new(32))

    return veth_pair_random_ip4_addr if selected_addr.network.to_s.nil? || vms.any? { |vm| vm.local_vetho_ip == selected_addr.network.to_s }
    selected_addr
  end

  def sshable_address
    assigned_host_addresses.find { |a| a.ip.version == 4 }
  end

  def spdk_cpu_count
    if total_cpus <= 64
      2
    else
      4
    end
  end

  def create_addresses(ip_records: nil)
    ip_records ||= Hosting::Apis.pull_ips(self)
    return if ip_records.nil? || ip_records.empty?

    DB.transaction do
      ip_records.each do |ip_record|
        ip_addr = ip_record.ip_address
        source_host_ip = ip_record.source_host_ip
        is_failover_ip = ip_record.is_failover

        next if assigned_subnets.any? { |a| a.cidr.to_s == ip_addr }

        # we need to find if it was previously created
        # if it was, we need to update the routed_to_host_id but only if there is no VM that's using it
        # if it wasn't, we need to create it
        adr = Address.where(cidr: ip_addr).first
        if adr && is_failover_ip
          if adr.assigned_vm_addresses.count > 0
            fail "BUG: failover ip #{ip_addr} is already assigned to a vm"
          end

          adr.update(routed_to_host_id: id)
        else
          if Sshable.where(host: source_host_ip).count == 0
            fail "BUG: source host #{source_host_ip} isn't added to the database"
          end
          adr = Address.create_with_id(cidr: ip_addr, routed_to_host_id: id, is_failover_ip: is_failover_ip)
        end

        unless is_failover_ip
          AssignedHostAddress.create_with_id(host_id: id, ip: ip_addr, address_id: adr.id)
        end
      end
    end

    Strand.create_with_id(prog: "SetupNftables", label: "start", stack: [{subject_id: id}])
  end

  # Operational Functions

  # Introduced for refreshing rhizome programs via REPL.
  def install_rhizome(install_specs: false)
    Strand.create_with_id(prog: "InstallRhizome", label: "start", stack: [{subject_id: id, target_folder: "host", install_specs: install_specs}])
  end

  # Introduced for downloading a new boot image via REPL.
  def download_boot_image(image_name, version:, custom_url: nil)
    Strand.create_with_id(prog: "DownloadBootImage", label: "start", stack: [{subject_id: id, image_name: image_name, custom_url: custom_url, version: version}])
  end

  # Introduced for downloading firmware via REPL.
  def download_firmware(version_x64: nil, version_arm64: nil, sha256_x64: nil, sha256_arm64: nil)
    version, sha256 = (arch == "x64") ? [version_x64, sha256_x64] : [version_arm64, sha256_arm64]
    fail ArgumentError, "No version provided" if version.nil?
    fail ArgumentError, "No SHA-256 digest provided" if sha256.nil?
    Strand.create_with_id(prog: "DownloadFirmware", label: "start", stack: [{subject_id: id, version: version, sha256: sha256}])
  end

  # Introduced for downloading cloud hypervisor via REPL.
  def download_cloud_hypervisor(version_x64: nil, version_arm64: nil, sha256_ch_bin_x64: nil, sha256_ch_bin_arm64: nil, sha256_ch_remote_x64: nil, sha256_ch_remote_arm64: nil)
    version, sha256_ch_bin, sha256_ch_remote = if arch == "x64"
      [version_x64, sha256_ch_bin_x64, sha256_ch_remote_x64]
    elsif arch == "arm64"
      [version_arm64, sha256_ch_bin_arm64, sha256_ch_remote_arm64]
    else
      fail "BUG: unexpected architecture"
    end
    fail ArgumentError, "No version provided" if version.nil?
    Strand.create_with_id(prog: "DownloadCloudHypervisor", label: "start", stack: [{subject_id: id, version: version, sha256_ch_bin: sha256_ch_bin, sha256_ch_remote: sha256_ch_remote}])
  end

  def hetznerify(server_id)
    DB.transaction do
      HostProvider.create(provider_name: HostProvider::HETZNER_PROVIDER_NAME, server_identifier: server_id) { it.id = id }
      create_addresses
    end
  end

  def set_data_center
    update(data_center: Hosting::Apis.pull_data_center(self))
  end

  def allow_slices
    update(accepts_slices: true)
  end

  def disallow_slices
    update(accepts_slices: false)
  end

  def set_server_name
    Hosting::Apis.set_server_name(self)
  end

  def reimage
    unless Config.development?
      fail "BUG: reimage is only allowed in development"
    end

    Hosting::Apis.reimage_server(self)
  end

  # Cuts power to a Server and starts it again. This forcefully stops it
  # without giving the Server operating system time to gracefully stop. This
  # may lead to data loss, it’s equivalent to pulling the power cord and
  # plugging it in again. Reset should only be used when reboot does not work.
  def hardware_reset
    Hosting::Apis.hardware_reset_server(self)
  end

  def check_storage_smartctl(ssh_session, devices)
    devices.map do |device_name|
      command = "sudo smartctl -j -H /dev/#{device_name}"
      command << " -d scsi" if device_name.start_with?("sd")
      command << " | jq .smart_status.passed"
      passed = ssh_session.exec!(command).strip == "true"
      Clog.emit("Device #{device_name} failed smartctl check on VmHost #{ubid}") unless passed
      passed
    end.all?(true)
  end

  def check_storage_nvme(ssh_session, devices)
    devices.reject { |device_name| !device_name.start_with?("nvme") }.map do |device_name|
      passed = ssh_session.exec!("sudo nvme smart-log /dev/#{device_name} | grep \"critical_warning\" | awk '{print $3}'").strip == "0"
      Clog.emit("Device #{device_name} failed nvme smart-log check on VmHost #{ubid}") unless passed
      passed
    end.all?(true)
  end

  def check_storage_read_write(ssh_session, devices)
    lsblk_json_info = ssh_session.exec!("lsblk --json")
    devices_with_mount_points = devices.map { |device| SystemParser.get_device_mount_points_from_lsblk_json(lsblk_json_info, device) }

    all_mount_points = []
    devices_with_mount_points.each do |device_mount_points|
      device_mount_points.each_value do |mount_points|
        all_mount_points.concat(mount_points)
      end
    end

    all_mount_points.uniq.all? do |mount_point|
      file_name = Shellwords.escape(File.join(mount_point, "test-file"))

      write_result = ssh_session.exec!("sudo bash -c \"head -c 1M </dev/zero > #{file_name}\"")
      write_status = write_result.exitstatus == 0
      hash_result = ssh_session.exec!("sha256sum #{file_name}")
      hash_status = hash_result.strip == "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58  #{file_name}"
      delete_result = ssh_session.exec!("sudo rm #{file_name}")
      delete_status = delete_result.exitstatus == 0

      unless write_status && hash_status && delete_status
        failure_reasons = []
        failure_reasons << "Write failed (exitstatus=#{write_result.exitstatus}, output=#{write_result.strip})" unless write_status
        failure_reasons << "Hash check failed (expected hash mismatch, output=#{hash_result.strip})" unless hash_status
        failure_reasons << "Delete failed (exitstatus=#{delete_result.exitstatus}, output=#{delete_result.strip})" unless delete_status

        Clog.emit("Failed to perform write/read/delete on mountpoint #{mount_point} on VmHost #{ubid}: #{failure_reasons.join("; ")}")
      end

      write_status && hash_status && delete_status
    end
  end

  def check_storage_kernel_logs(ssh_session, devices)
    kernel_logs = ssh_session.exec!("journalctl -kS -1min --no-pager")
    return false unless kernel_logs.exitstatus == 0

    error_count = kernel_logs.scan(/Buffer I\/O error on dev (\w+)/).tally
    Clog.emit("found error on kernel logs. devices with error_count: #{error_count} on VmHost #{ubid}") unless error_count.empty?
    error_count.empty?
  end

  def init_health_monitor_session
    {
      ssh_session: sshable.start_fresh_session
    }
  end

  def init_metrics_export_session
    {
      ssh_session: sshable.start_fresh_session
    }
  end

  def disk_device_ids
    # we use this next line to migrate data from the old formatting (storing device names) to the new (storing id) so we trigger the convert
    # whenever an element inside unix_device_list is not a SSD or NVMe id.
    # SSD and NVMe ids start with wwn or nvme-eui respectively.
    # YYY: This next line can be removed in the future after the first run of the code.
    storage_devices.each { |sd| sd.migrate_device_name_to_device_id if sd.unix_device_list.any? { |device_name| device_name !~ /\A(wwn|nvme-eui)/i } }
    storage_devices.flat_map { |sd| sd.unix_device_list }
  end

  def disk_device_names(ssh_session)
    disk_device_ids.map { |id| ssh_session.exec!("readlink -f /dev/disk/by-id/#{id}").delete_prefix("/dev/").strip }
  end

  def perform_health_checks(ssh_session)
    device_names = disk_device_names(ssh_session)
    check_storage_smartctl(ssh_session, device_names) &&
      check_storage_nvme(ssh_session, device_names) &&
      check_storage_read_write(ssh_session, device_names) &&
      check_storage_kernel_logs(ssh_session, device_names)
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      perform_health_checks(session[:ssh_session]) ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end

  def available_storage_gib
    storage_devices.sum(&:available_storage_gib)
  end

  def total_storage_gib
    storage_devices.sum(&:total_storage_gib)
  end

  def render_arch(arm64:, x64:)
    case arch
    when "arm64"
      arm64
    when "x64"
      x64
    else
      fail "BUG: inexhaustive render code"
    end
  end

  def metrics_config
    {
      endpoints: [
        "http://localhost:9100/metrics"
      ],
      max_file_retention: 120,
      interval: "15s",
      additional_labels: {ubicloud_resource_id: ubid},
      metrics_dir: "/home/rhizome/host/metrics",
      project_id: Config.monitoring_service_project_id
    }
  end
end

# Table: vm_host
# Columns:
#  id                 | uuid                     | PRIMARY KEY
#  allocation_state   | allocation_state         | NOT NULL DEFAULT 'unprepared'::allocation_state
#  ip6                | inet                     |
#  net6               | cidr                     |
#  total_mem_gib      | integer                  |
#  total_sockets      | integer                  |
#  total_cores        | integer                  |
#  total_cpus         | integer                  |
#  used_cores         | integer                  | NOT NULL DEFAULT 0
#  ndp_needed         | boolean                  | NOT NULL DEFAULT false
#  total_hugepages_1g | integer                  | NOT NULL DEFAULT 0
#  used_hugepages_1g  | integer                  | NOT NULL DEFAULT 0
#  last_boot_id       | text                     |
#  created_at         | timestamp with time zone | NOT NULL DEFAULT now()
#  data_center        | text                     |
#  arch               | arch                     |
#  total_dies         | integer                  |
#  os_version         | text                     |
#  accepts_slices     | boolean                  | NOT NULL DEFAULT false
#  location_id        | uuid                     | NOT NULL
#  family             | text                     | NOT NULL
# Indexes:
#  vm_host_pkey     | PRIMARY KEY btree (id)
#  vm_host_ip6_key  | UNIQUE btree (ip6)
#  vm_host_net6_key | UNIQUE btree (net6)
# Check constraints:
#  core_allocation_limit      | (used_cores <= total_cores)
#  hugepages_allocation_limit | (used_hugepages_1g <= total_hugepages_1g)
#  used_cores_above_zero      | (used_cores >= 0)
# Foreign key constraints:
#  vm_host_id_fkey          | (id) REFERENCES sshable(id)
#  vm_host_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  address               | address_routed_to_host_id_fkey      | (routed_to_host_id) REFERENCES vm_host(id)
#  assigned_host_address | assigned_host_address_host_id_fkey  | (host_id) REFERENCES vm_host(id)
#  boot_image            | boot_image_vm_host_id_fkey          | (vm_host_id) REFERENCES vm_host(id)
#  host_provider         | host_provider_id_fkey               | (id) REFERENCES vm_host(id)
#  pci_device            | pci_device_vm_host_id_fkey          | (vm_host_id) REFERENCES vm_host(id)
#  spdk_installation     | spdk_installation_vm_host_id_fkey   | (vm_host_id) REFERENCES vm_host(id)
#  storage_device        | storage_device_vm_host_id_fkey      | (vm_host_id) REFERENCES vm_host(id)
#  vhost_block_backend   | vhost_block_backend_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
#  vm                    | vm_vm_host_id_fkey                  | (vm_host_id) REFERENCES vm_host(id)
#  vm_host_cpu           | vm_host_cpu_vm_host_id_fkey         | (vm_host_id) REFERENCES vm_host(id)
#  vm_host_slice         | vm_host_slice_vm_host_id_fkey       | (vm_host_id) REFERENCES vm_host(id)
