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

  # Prove the config parses and generates before touching the live directory, so
  # a rejected one cannot leave the host with no netplan at all. Stage it at the
  # mode the live copy gets: netplan warns, without failing, about a config
  # others can read, and the staged copy holds the same bytes.
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

  # Swap 01-netcfg.yaml to the new config in place, preserving the one it
  # displaces first. safe_write_to_file lands the replacement with one atomic
  # rename, so 01-netcfg.yaml holds either the old or the new config at every
  # instant: a crash or reboot mid-run never finds /etc/netplan empty. Copy,
  # don't move, what we displace -- the live file has to stay put until that
  # rename replaces it -- but copy to a temp and rename it onto the archive
  # suffix, so a crash mid-copy leaves the prior archive whole rather than
  # truncated, the atomicity the old rename-everything archive had. Set 0600 in
  # the write itself: a separate chmod exposes the addressing at 0644 until it
  # runs, and a crash before it strands the file there, warned about by every
  # later netplan run.
  def install
    if File.exist?(NETPLAN_PATH)
      target = archive_target(NETPLAN_PATH)
      tmp = "#{target}.tmp"
      FileUtils.cp(NETPLAN_PATH, tmp, preserve: true)
      File.rename(tmp, target)
    end
    safe_write_to_file(NETPLAN_PATH, @netplan, perm: 0o600)
  end

  # The control plane sends the complete desired state, so replace the
  # directory's contents rather than patch them: netplan merges every *.yaml,
  # and the stock cloud-init config sorts after ours and would win. #install has
  # already put 01-netcfg.yaml in place, so displace only the others, and only
  # now: renaming them before it lands would reopen the empty-directory window.
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

  # Where a displaced config is preserved. These suffixes are this script's to
  # write; given that, the first config displaced at a name settles in
  # .ubicloud-orig and stays, and .ubicloud-disabled rotates one deep behind it.
  # A bare .orig would collide with what an operator's own backup of a
  # hand-written config tends to be called.
  def archive_target(path)
    orig = path + ".ubicloud-orig"
    File.exist?(orig) ? path + ".ubicloud-disabled" : orig
  end
end
