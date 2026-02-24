# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"
require "json"
require "base64"
require "pathname"
require_relative "storage_key_encryption"
require_relative "vm_path"

module VmFscrypt
  DEK_DIR = "/vm/.fscrypt_keys"

  def self.dek_path(vm_name)
    File.join(DEK_DIR, "#{vm_name}.json")
  end

  def self.dek_new_path(vm_name)
    "#{dek_path(vm_name)}.new"
  end

  # Encrypt an empty /vm/{vm_name}/ directory with fscryptctl.
  # Wraps master_key_binary with KEK and stores at /vm/.fscrypt_keys/{vm_name}.json.
  # Adds master key to kernel keyring and sets fscrypt v2 policy on directory.
  def self.encrypt(vm_name, kek_secrets, master_key_binary)
    vm_home = VmPath.new(vm_name).home("")
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)
    fail "Directory is not empty: #{vm_home}" unless (Dir.entries(vm_home) - %w[. ..]).empty?

    FileUtils.mkdir_p(DEK_DIR, mode: 0o700)
    write_wrapped_dek(dek_path(vm_name), kek_secrets, master_key_binary)

    mnt = mountpoint_of(vm_home).shellescape
    identifier = r("fscryptctl add_key #{mnt}", stdin: master_key_binary).strip
    r("fscryptctl set_policy #{identifier} #{vm_home.shellescape}")
  end

  # Add the fscrypt master key to the kernel keyring for /vm/{vm_name}/.
  # Reads wrapped DEK from disk, unwraps with KEK, passes to fscryptctl add_key.
  # Idempotent: kernel returns same identifier if key already added.
  # Returns silently if no DEK file exists (pre-fscrypt VM).
  def self.add_key(vm_name, kek_secrets)
    vm_home = VmPath.new(vm_name).home("")
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)

    dek_file = dek_path(vm_name)
    return unless File.exist?(dek_file)

    master_key_binary = read_unwrapped_dek(dek_file, kek_secrets)
    mnt = mountpoint_of(vm_home).shellescape
    r("fscryptctl add_key #{mnt}", stdin: master_key_binary)
  end

  # Remove the fscrypt master key from the kernel keyring for a VM directory.
  # Called during VM destruction (purge_user) to avoid leaking keyring entries
  # on hosts with high VM churn.
  # Tolerates: directory not encrypted, key already removed, directory gone.
  # Surfaces: wrong mountpoint, kernel errors, unexpected failures.
  def self.remove_key(vm_name)
    vm_home = VmPath.new(vm_name).home("")
    return unless File.directory?(vm_home)

    mnt = mountpoint_of(vm_home).shellescape
    identifier = r("fscryptctl get_policy #{vm_home.shellescape}").strip
    r("fscryptctl remove_key #{identifier} #{mnt}")
  rescue CommandFail => ex
    raise unless /Error getting policy|ENODATA|not encrypted|No such file|key not present/i.match?(ex.stderr + ex.message)
  end

  # Remove the wrapped DEK file(s) for a VM.
  # Uses FileUtils.rm instead of rm_f so permission errors (EPERM, EACCES)
  # are surfaced rather than silently swallowed.
  def self.purge(vm_name)
    [dek_path(vm_name), dek_new_path(vm_name)].each do |path|
      FileUtils.rm(path)
    rescue Errno::ENOENT
      # Already removed (idempotent)
    end
  end

  # Re-encrypt the DEK file with a new KEK (writes to .new file).
  # Part of KEK rotation: phase 1 of 3.
  def self.reencrypt(vm_name, old_kek, new_kek)
    master_key_binary = read_unwrapped_dek(dek_path(vm_name), old_kek)
    write_wrapped_dek(dek_new_path(vm_name), new_kek, master_key_binary)
  end

  # Verify both old and new DEK files contain the same master key.
  # Part of KEK rotation: phase 2 of 3.
  def self.test_keys(vm_name, old_kek, new_kek)
    old_dek = read_unwrapped_dek(dek_path(vm_name), old_kek)
    new_dek = read_unwrapped_dek(dek_new_path(vm_name), new_kek)
    fail "DEK mismatch after reencrypt" unless old_dek == new_dek
  end

  # Promote the new DEK file (atomic rename).
  # Part of KEK rotation: phase 3 of 3.
  # Idempotent: if .new doesn't exist (already renamed on a prior attempt),
  # this is a no-op. The rescue is scoped to just the rename so errors from
  # sync_parent_dir (missing parent dir, etc.) are not swallowed.
  def self.retire_old(vm_name)
    begin
      File.rename(dek_new_path(vm_name), dek_path(vm_name))
    rescue Errno::ENOENT
      return # .new was already renamed on a prior attempt
    end
    sync_parent_dir(dek_path(vm_name))
  end

  def self.write_wrapped_dek(path, kek_secrets, master_key_binary)
    sek = StorageKeyEncryption.new(kek_secrets)
    wrapped = sek.wrap_key(master_key_binary)
    wrapped_b64 = wrapped.map { |s| Base64.strict_encode64(s) }
    File.open(path, "w", 0o600) { |f|
      f.write(JSON.pretty_generate({
        "cipher" => "fscrypt-v2",
        "key" => wrapped_b64
      }))
      fsync_or_fail(f)
    }
    sync_parent_dir(path)
  end

  def self.read_unwrapped_dek(path, kek_secrets)
    data = JSON.parse(File.read(path))
    wrapped_b64 = data["key"]
    wrapped = wrapped_b64.map { |s| Base64.decode64(s) }
    sek = StorageKeyEncryption.new(kek_secrets)
    sek.unwrap_key(wrapped)
  end

  def self.mountpoint_of(path)
    p = Pathname.new(path)
    p = p.parent until p.mountpoint?
    p.to_s
  end

  private_class_method :write_wrapped_dek, :read_unwrapped_dek, :mountpoint_of
end
