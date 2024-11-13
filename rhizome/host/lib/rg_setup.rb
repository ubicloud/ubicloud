# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

class ResourceGroupSetup
  def initialize(rg_name)
    @rg_name = rg_name
  end

  def systemd_service
    @systemd_service ||= File.join("/etc/systemd/system", @rg_name)
  end

  def prep(allowed_cpus)
    install_systemd_unit(allowed_cpus)
    start_systemd_unit
  end

  def purge
    if File.exist? systemd_service
      r "systemctl stop #{@rg_name}"
      FileUtils.rm_f(systemd_service)

      r "systemctl daemon-reload"
    end
  end

  def install_systemd_unit(allowed_cpus)
    fail "BUG: unit name must not be empty" if @rg_name.empty?
    fail "BUG: we cannot create system units" if @rg_name == "system.slice" || @rg_name == "user.slice"
    fail "BUG: unit name cannot contain a dash" if @rg_name.include?("-")

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
    r "systemctl start #{@rg_name}"
    r "echo \"root\" > /sys/fs/cgroup/#{@rg_name}/cpuset.cpus.partition"
  end
end
