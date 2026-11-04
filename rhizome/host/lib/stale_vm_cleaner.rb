# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "vm_setup"
require_relative "slice_setup"
require "json"

# Purges VM and slice artifacts left behind on a host when the control plane
# destroyed a VM while the host was draining (and thus unreachable), so the
# host-side cleanup could not run. The artifacts live on (systemd units, netns,
# user, /vm files, storage, hugepages) until the host is reachable again, but
# no control-plane strand remains to re-run the deletion.
#
# The control plane supplies the set of inhost names it still expects to exist
# (live VMs and live slices). Anything on the host that matches the VM/slice
# naming pattern but is not expected is stale and is cleaned up. Purging is
# idempotent: the underlying VM/slice setup tolerates already-missing state.
class StaleVmCleaner
  VM_HOME_DIR = "/vm"
  SYSTEMD_UNIT_DIR = "/etc/systemd/system"

  # VM inhost names are "vm" followed by 6 chars from the ubicloud base32
  # alphabet (digits and `a-h`, `j`, `k`, `m`, `n`, `p-z`; excludes i/l/o/u).
  # Narrow enough that we never touch unrelated host state.
  VM_NAME_RE = /\Avm[0-9a-hj-km-np-tv-z]{6}\z/

  # Slice systemd units are "<family>_vm<inhost>.slice"; the "_vm" segment
  # (a VM-derived inhost name) marks a slice as ours. See
  # VmHostSlice#inhost_name and Scheduling::Allocator.
  SLICE_NAME_RE = /\A[a-z0-9]+_vm[0-9a-hj-km-np-tv-z]{6}\.slice\z/

  def initialize(expected_vm_names: [], expected_slice_names: [])
    @expected_vm_names = expected_vm_names
    @expected_slice_names = expected_slice_names
  end

  # A freshly-provisioned host may not have created the VM staging directory
  # yet; treat a missing (or unreadable, e.g. on a wiped disk) dir as empty.
  def self.dir_children(path)
    Dir.children(path)
  rescue SystemCallError
    []
  end

  def self.vm_names_from_vm_dir
    dir_children(VM_HOME_DIR).select { |name| VM_NAME_RE.match?(name) }
  end

  def self.slice_names_from_unit_dir
    dir_children(SYSTEMD_UNIT_DIR).select { |name| SLICE_NAME_RE.match?(name) }
  end

  # Returns a hash of what was cleaned up: {"vms" => [...], "slices" => [...]}
  def clean
    cleaned_vms = stale_vm_names.each { |name| purge_vm(name) }
    cleaned_slices = stale_slice_names.each { |name| purge_slice(name) }
    {"vms" => cleaned_vms, "slices" => cleaned_slices}
  end

  def stale_vm_names
    self.class.vm_names_from_vm_dir - @expected_vm_names
  end

  def stale_slice_names
    self.class.slice_names_from_unit_dir - @expected_slice_names
  end

  def purge_vm(name)
    stop_unit(name)
    stop_unit("#{name}-dnsmasq")
    params = vm_params(name)
    VmSetup.new(
      name,
      hugepages: params.fetch("hugepages", true),
      ch_version: params["ch_version"],
      firmware_version: params["firmware_version"],
    ).purge
  end

  def purge_slice(name)
    SliceSetup.new(name).purge
  end

  # Same tolerance as setup-vm: delete actions work even when the prep file has
  # already been removed.
  private def vm_params(name)
    JSON.parse(File.read(VmPath.new(name).prep_json))
  rescue Errno::ENOENT
    {}
  end

  private def stop_unit(name)
    r "systemctl", "stop", name
  rescue CommandFail => ex
    raise unless /Failed to stop .* Unit .* not loaded\./.match?(ex.stderr)
  end
end
