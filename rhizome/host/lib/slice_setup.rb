# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

class SliceSetup
  def initialize(slice_name)
    @slice_name = slice_name
  end

  def systemd_service
    @systemd_service ||= File.join("/etc/systemd/system", @slice_name)
  end

  def prep(allowed_cpus)
    fail "BUG: invalid cpuset" unless valid_cpuset?(allowed_cpus)
    install_systemd_unit(allowed_cpus)
    start_systemd_unit
  end

  def purge
    r("systemctl stop #{@slice_name.shellescape}", expect: [0, 5])
    rm_if_exists systemd_service
    r "systemctl daemon-reload"
  end

  def install_systemd_unit(allowed_cpus)
    fail "BUG: unit name must not be empty" if @slice_name.empty?
    fail "BUG: we cannot create system units" if @slice_name == "system.slice" || @slice_name == "user.slice"
    fail "BUG: unit name cannot contain a dash" if @slice_name.include?("-")
    fail "BUG: invalid allowed_cpus" if !valid_cpuset?(allowed_cpus)

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
    cpuset_path = File.join("/sys/fs/cgroup", @slice_name, "cpuset.cpus.partition")
    File.write(cpuset_path, "root")
  end

  def valid_cpuset?(str)
    return false if str.nil? || str.empty?
    str.split(",").all? do |part|
      if part.include?("-")
        r = part.split("-")
        r.size == 2 && r.all? { it.to_i.to_s == it } && r[0].to_i <= r[1].to_i
      else
        part.to_i.to_s == part
      end
    end
  end
end
