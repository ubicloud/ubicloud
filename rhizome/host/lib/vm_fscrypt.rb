# frozen_string_literal: true

require "fileutils"
require "json"
require "base64"
require "pathname"
require_relative "../../common/lib/util"
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

  # Unlock an fscrypt-encrypted /vm/{vm_name}/ directory.
  # Reads wrapped DEK from disk, unwraps with KEK, adds to kernel keyring.
  # Idempotent: kernel returns same identifier if key already added.
  # Returns silently if no DEK file exists (pre-fscrypt VM).
  def self.unlock(vm_name, kek_secrets)
    vm_home = VmPath.new(vm_name).home("")
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)

    dek_file = dek_path(vm_name)
    return unless File.exist?(dek_file)

    master_key_binary = read_unwrapped_dek(dek_file, kek_secrets)
    mnt = mountpoint_of(vm_home).shellescape
    r("fscryptctl add_key #{mnt}", stdin: master_key_binary)
  end

  # Lock an fscrypt-encrypted /vm/{vm_name}/ directory.
  # Best-effort: does not fail if already locked, not encrypted, or has open FDs.
  def self.lock(vm_name)
    vm_home = VmPath.new(vm_name).home("")
    return unless File.directory?(vm_home)

    mnt = mountpoint_of(vm_home).shellescape
    identifier = r("fscryptctl get_policy #{vm_home.shellescape}").strip
    r("fscryptctl remove_key #{identifier} #{mnt}")
  rescue CommandFail
    # Ignore failures (may already be locked, not encrypted, etc.)
  end

  # Remove the wrapped DEK file(s) for a VM.
  def self.purge(vm_name)
    FileUtils.rm_f(dek_path(vm_name))
    FileUtils.rm_f(dek_new_path(vm_name))
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
  # this is a no-op.
  def self.retire_old(vm_name)
    File.rename(dek_new_path(vm_name), dek_path(vm_name))
    sync_parent_dir(dek_path(vm_name))
  rescue Errno::ENOENT
    # .new was already renamed to .json on a previous attempt
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
