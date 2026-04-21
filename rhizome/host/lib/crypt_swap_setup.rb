# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "device_resolver"

require "fileutils"

module CryptSwapSetup
  extend DeviceResolver

  module_function

  FSTAB = "/etc/fstab"
  CRYPTTAB = "/etc/crypttab"
  CRYPTSWAP_DEVICE = "/dev/mapper/cryptswap"

  def run
    fstab = File.read(FSTAB).lines
    if fstab.any? { |l| l.include?(CRYPTSWAP_DEVICE) }
      puts "cryptswap already configured, skipping"
      return
    end

    swap_line_idx = fstab.find_index { |l| l.split[2] == "swap" }
    fail "No swap entry found in /etc/fstab" unless swap_line_idx

    swap_real = resolve_swap_device(fstab[swap_line_idx])
    by_id = persistent_device_id(swap_real, device_node: true)

    r "swapoff", swap_real

    add_crypttab_entry("cryptswap #{by_id} /dev/urandom cipher=aes-xts-plain64,size=512,swap,discard\n")

    fstab[swap_line_idx] = "#{CRYPTSWAP_DEVICE} none swap sw 0 0\n"
    update_fstab(fstab)

    activate(swap_real)
  end

  # Returns the realpath of the backing swap device.
  def resolve_swap_device(swap_line)
    source = swap_line.split.first
      .sub(/\AUUID=/, "/dev/disk/by-uuid/")
      .sub(/\ALABEL=/, "/dev/disk/by-label/")
    File.realpath(source)
  end

  def add_crypttab_entry(entry)
    existing = ""
    if File.exist?(CRYPTTAB)
      FileUtils.cp(CRYPTTAB, "#{CRYPTTAB}.bak.#{Time.now.to_i}")
      existing = File.read(CRYPTTAB)
    end
    safe_write_to_file(CRYPTTAB, existing.gsub(/^cryptswap\s.*\n?/, "") + entry)
  end

  def update_fstab(fstab)
    FileUtils.cp(FSTAB, "#{FSTAB}.bak.#{Time.now.to_i}")
    safe_write_to_file(FSTAB, fstab.join)
  end

  def activate(swap_real)
    # Prevent interactive prompt about existing swap signature on the backing device.
    r "wipefs", "-a", swap_real
    r "systemctl", "daemon-reload"
    r "systemctl", "restart", "systemd-cryptsetup@cryptswap.service"
    r "mkswap", "-f", CRYPTSWAP_DEVICE
    r "swapon", "-a"
  end
end
