# frozen_string_literal: true

require_relative "../../common/lib/util"

module VmSetupFscrypt
  # Encrypt an empty /vm/{vm_name}/ directory with fscrypt using a raw 32-byte key
  # provided via stdin. The directory must exist and be empty.
  def self.encrypt(vm_name, key_binary)
    vm_home = File.join("", "vm", vm_name)
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)
    fail "Directory is not empty: #{vm_home}" unless (Dir.entries(vm_home) - %w[. ..]).empty?
    fail "Stale protector exists for #{vm_name}" if find_protector_id_by_name(vm_name)

    # Write key to a temp file for fscrypt (raw_key source requires a file path)
    key_file = File.join("", "tmp", "fscrypt-key-#{vm_name}-#{$$}")
    begin
      File.open(key_file, "w", 0o600) { |f| f.write(key_binary) }
      r "fscrypt encrypt #{vm_home.shellescape} --source=raw_key --name=#{vm_name.shellescape} --key=#{key_file.shellescape} --quiet"
    ensure
      FileUtils.rm_f(key_file)
    end
  end

  # Unlock an fscrypt-encrypted /vm/{vm_name}/ directory using a raw 32-byte key.
  def self.unlock(vm_name, key_binary)
    vm_home = File.join("", "vm", vm_name)
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)

    # Check if already unlocked by trying to list contents
    begin
      Dir.entries(vm_home)
      # If we can list entries without error, check if it's actually encrypted
      status = `fscrypt status #{vm_home.shellescape} 2>&1`
      return if status.include?("Unlocked: Yes")
      # If the directory is not an fscrypt directory at all, return silently
      # (handles pre-existing VMs created before encryption was enabled)
      return unless status.include?("Encrypted: true") || status.include?("Unlocked: No")
    rescue Errno::ENOKEY, Errno::ENOENT
      # Directory is locked, proceed with unlock
    end

    key_file = File.join("", "tmp", "fscrypt-key-#{vm_name}-#{$$}")
    begin
      File.open(key_file, "w", 0o600) { |f| f.write(key_binary) }
      r "fscrypt unlock #{vm_home.shellescape} --key=#{key_file.shellescape} --quiet"
    ensure
      FileUtils.rm_f(key_file)
    end
  end

  # Lock an fscrypt-encrypted /vm/{vm_name}/ directory.
  # Best-effort: does not fail if already locked, not encrypted, or has open FDs.
  def self.lock(vm_name)
    vm_home = File.join("", "vm", vm_name)
    return unless File.directory?(vm_home)

    r "fscrypt lock #{vm_home.shellescape} --quiet"
  rescue CommandFail
    # Ignore lock failures (may already be locked, may have open FDs, may not be encrypted)
  end

  # Clean up orphaned fscrypt metadata (policy and protector) after deleting
  # the encrypted directory. Call this after deluser --remove-home.
  def self.purge_metadata(vm_name)
    # List protectors and find the one named after this VM
    output = `fscrypt status / 2>&1`
    return unless output.include?("PROTECTOR")

    # Parse protector IDs for this VM's named protector
    output.each_line do |line|
      # Format: "PROTECTOR  LINKED  DESCRIPTION"
      # e.g.    "abc123def  No      Raw key protector \"vm_name\""
      if line.include?(vm_name)
        protector_id = line.strip.split(/\s+/).first
        next if protector_id.nil? || protector_id.empty? || protector_id == "PROTECTOR"
        begin
          r "fscrypt metadata destroy --protector=/:#{protector_id} --force --quiet"
        rescue CommandFail
          # Ignore cleanup failures
        end
      end
    end
  end
end
