# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

class VmHostSliceSetup
  def initialize(slice_name)
    @slice_name = slice_name
  end

  def systemd_service
    @systemd_service ||= File.join("/etc/systemd/system", @slice_name)
  end

  def prep(allowed_cpus)
    install_systemd_unit(allowed_cpus)
    start_systemd_unit
  end

  def purge
    if File.exist? systemd_service
      r "systemctl stop #{@slice_name}"
      FileUtils.rm_f(systemd_service)

      r "systemctl daemon-reload"
    end
  end

  def install_systemd_unit(allowed_cpus)
    fail "BUG: unit name must not be empty" if @slice_name.empty?
    fail "BUG: we cannot create system units" if @slice_name == "system.slice" || @slice_name == "user.slice"
    fail "BUG: unit name cannot contain a dash" if @slice_name.include?("-")

    # Only proceed if the slice has not yet been setup
    unless File.exist? systemd_service
      safe_write_to_file(systemd_service, <<SLICE_CONFIG)
[Unit]
Description=Restricting resouces for virtual machines
Before=slices.target
[Slice]
AllowedCPUs=#{allowed_cpus}
SLICE_CONFIG

      r "systemctl daemon-reload"
    end
  end

  def start_systemd_unit
    r "systemctl start #{@slice_name}"
    r "echo \"root\" > /sys/fs/cgroup/#{@slice_name}/cpuset.cpus.partition"
  end
end
