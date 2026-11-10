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
  CRYPTSETUP_GENERATOR = "/usr/lib/systemd/system-generators/systemd-cryptsetup-generator"

  def run
    fstab = File.read(FSTAB).lines
    if fstab.any? { |l| l.include?(CRYPTSWAP_DEVICE) }
      if cryptswap_active?
        puts "cryptswap already configured, skipping"
      else
        # A previous run configured crypttab/fstab but failed before swap was
        # activated, so finish activation.
        puts "cryptswap configured but not active, activating"
        ensure_cryptsetup_generator
        activate_cryptswap
      end
      return
    end

    swap_line_idx = fstab.find_index { |l| l.split[2] == "swap" }
    unless swap_line_idx
      puts "no swap entry in #{FSTAB}; skipping cryptswap setup"
      return
    end

    swap_real = resolve_swap_device(fstab[swap_line_idx])

    # dm-crypt needs a block device; we can't encrypt a swapfile in place.
    unless File.blockdev?(swap_real)
      puts "swap is a file (#{swap_real}), not a block device; skipping cryptswap setup"
      return
    end

    by_id = persistent_device_id(swap_real, device_node: true)

    # Without the generator, systemd ignores /etc/crypttab. It is a separate
    # package on Debian 13 and not part of the base image. Install it before
    # making any changes, so a failure leaves the original swap in place.
    ensure_cryptsetup_generator

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

  def ensure_cryptsetup_generator
    r "apt-get", "-y", "install", "systemd-cryptsetup" unless File.exist?(CRYPTSETUP_GENERATOR)
  end

  def cryptswap_active?
    return false unless File.exist?(CRYPTSWAP_DEVICE)
    cryptswap = File.realpath(CRYPTSWAP_DEVICE)
    File.read("/proc/swaps").lines.drop(1).any? { |l| File.realpath(l.split.first) == cryptswap }
  end

  def activate(swap_real)
    # Prevent interactive prompt about existing swap signature on the backing device.
    r "wipefs", "-a", swap_real
    activate_cryptswap
  end

  def activate_cryptswap
    r "systemctl", "daemon-reload"
    r "systemctl", "restart", "systemd-cryptsetup@cryptswap.service"
    r "mkswap", "-f", CRYPTSWAP_DEVICE
    r "swapon", "-a"
  end
end
