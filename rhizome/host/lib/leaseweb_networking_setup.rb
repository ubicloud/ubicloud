# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

class LeasewebNetworkingSetup
  NETPLAN_DIR = "/etc/netplan"
  NETPLAN_PATH = File.join(NETPLAN_DIR, "01-netcfg.yaml")
  STAGING_DIR = "/var/tmp/leaseweb-netplan"

  def initialize(netplan)
    @netplan = netplan
  end

  def run
    generate
    install
    archive
    apply
  end

  private

  # Validate in a scratch root so a rejected config never reaches /etc/netplan.
  def generate
    staged = File.join(STAGING_DIR, "etc/netplan")
    staged_path = File.join(staged, "01-netcfg.yaml")
    FileUtils.rm_rf(STAGING_DIR)
    FileUtils.mkdir_p(staged, mode: 0o700)
    File.write(staged_path, @netplan)
    FileUtils.chmod(0o600, staged_path)
    r "netplan generate --root-dir #{STAGING_DIR}"
    FileUtils.rm_rf(STAGING_DIR)
  end

  # Copy the current config aside, then replace it atomically, so 01-netcfg.yaml
  # is never absent for a crash to find.
  def install
    if File.exist?(NETPLAN_PATH)
      target = archive_target(NETPLAN_PATH)
      tmp = "#{target}.tmp"
      FileUtils.cp(NETPLAN_PATH, tmp, preserve: true)
      File.rename(tmp, target)
    end
    safe_write_to_file(NETPLAN_PATH, @netplan, perm: 0o600)
  end

  # Runs after #install lands ours: netplan merges every *.yaml, so displacing
  # the stock configs sooner could leave it with none.
  def archive
    Dir.glob(File.join(NETPLAN_DIR, "*.yaml")).each do |path|
      next if path == NETPLAN_PATH

      File.rename(path, archive_target(path))
    end
  end

  def apply
    r "netplan generate"
    r "netplan apply"
  end

  # First config displaced at a name stays under .ubicloud-orig; later ones
  # rotate through .ubicloud-disabled.
  def archive_target(path)
    orig = path + ".ubicloud-orig"
    File.exist?(orig) ? path + ".ubicloud-disabled" : orig
  end
end
