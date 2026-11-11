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
  PROC_SWAPS = "/proc/swaps"

  def run
    fstab = File.read(FSTAB).lines
    swap_line_idxs = fstab.each_index.select { |i| fstab[i].split[2] == "swap" && !fstab[i].lstrip.start_with?("#") }

    # Only one swap device can be encrypted here. Turn them all off rather
    # than leave any of them in plaintext.
    if swap_line_idxs.size > 1
      puts "#{swap_line_idxs.size} swap entries in #{FSTAB}; disabling all of them, as plaintext swap is not allowed"
      disable_swaps(fstab, swap_line_idxs)
      return
    end

    if fstab.any? { |l| l.include?(CRYPTSWAP_DEVICE) }
      puts "cryptswap already configured, skipping"
      return
    end

    swap_line_idx = swap_line_idxs.first
    unless swap_line_idx
      puts "no swap entry in #{FSTAB}; skipping cryptswap setup"
      return
    end

    swap_real = resolve_swap_device(fstab[swap_line_idx])

    # dm-crypt needs a block device, so a swap file can't be encrypted here.
    # Plaintext swap can put any process memory, keys included, on disk, so
    # turn the swap file off instead.
    unless File.blockdev?(swap_real)
      puts "swap is a file (#{swap_real}); disabling it, as plaintext swap is not allowed"
      disable_swaps(fstab, [swap_line_idx])
      return
    end

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

  def disable_swaps(fstab, swap_line_idxs)
    swaps = swap_line_idxs.map { |i| resolve_swap_device(fstab[i]) }
    swaps.each { |swap| r "swapoff", swap if active_swap?(swap) }
    swap_line_idxs.reverse_each { |i| fstab.delete_at(i) }
    update_fstab(fstab)
    swaps.each { |swap| rm_if_exists(swap) unless File.blockdev?(swap) }
  end

  def active_swap?(path)
    File.readlines(PROC_SWAPS).drop(1).any? { |entry| entry.split.first == path }
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
