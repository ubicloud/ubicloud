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

  # Add a new protector to the directory's fscrypt policy using new_key_binary,
  # so both old and new keys can unlock the directory (overlap begins).
  # The directory must be unlocked first (using old_key_binary).
  # Idempotent: checks for existing "-rotate" protector name before creating.
  def self.add_protector(vm_name, old_key_binary, new_key_binary)
    vm_home = File.join("", "vm", vm_name)
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)

    # Ensure directory is unlocked (needed to add protector to policy)
    unlock(vm_name, old_key_binary)

    # Get the policy ID from directory status
    dir_status = `fscrypt status #{vm_home.shellescape} 2>&1`
    policy_id = dir_status[/Policy:\s+(\w+)/, 1]
    fail "Cannot find fscrypt policy for #{vm_home}" unless policy_id

    # Check if new protector already exists (idempotent retry)
    rotate_name = "#{vm_name}-rotate"
    root_status = `fscrypt status / 2>&1`
    if root_status.include?("\"#{rotate_name}\"")
      return
    end

    # Find the old protector ID (for authorizing the add-protector-to-policy)
    old_protector_id = find_protector_id(vm_name)

    new_key_file = File.join("", "tmp", "fscrypt-newkey-#{vm_name}-#{$$}")
    old_key_file = File.join("", "tmp", "fscrypt-oldkey-#{vm_name}-#{$$}")
    begin
      File.open(new_key_file, "w", 0o600) { |f| f.write(new_key_binary) }
      File.open(old_key_file, "w", 0o600) { |f| f.write(old_key_binary) }

      # Create the new protector on the root filesystem
      output = r "fscrypt metadata create protector / --source=raw_key --name=#{rotate_name.shellescape} --key=#{new_key_file.shellescape} --quiet"
      new_protector_id = output.strip
      fail "Failed to create protector" if new_protector_id.empty?

      # Link new protector to the policy (authorize with old protector's key)
      r "fscrypt metadata add-protector-to-policy --protector=/:#{new_protector_id} --policy=/:#{policy_id} --unlock-with=/:#{old_protector_id} --key=#{old_key_file.shellescape} --quiet"
    ensure
      FileUtils.rm_f(new_key_file)
      FileUtils.rm_f(old_key_file)
    end
  end

  # Remove all protectors except the one named "{vm_name}-rotate" (the new key).
  # Called after DB promotion — the "-rotate" protector holds the now-active key.
  # Idempotent: tolerates already-removed protectors.
  def self.remove_old_protectors(vm_name, keep_key_binary)
    vm_home = File.join("", "vm", vm_name)
    return unless File.directory?(vm_home)

    dir_status = `fscrypt status #{vm_home.shellescape} 2>&1`
    policy_id = dir_status[/Policy:\s+(\w+)/, 1]
    return unless policy_id

    rotate_name = "#{vm_name}-rotate"
    root_status = `fscrypt status / 2>&1`

    # Find protectors associated with this VM. Parse lines matching vm_name.
    root_status.each_line do |line|
      next unless line.include?("\"#{vm_name}\"") && !line.include?("\"#{rotate_name}\"")
      protector_id = line.strip.split(/\s+/).first
      next if protector_id.nil? || protector_id.empty? || protector_id == "PROTECTOR"

      begin
        r "fscrypt metadata remove-protector-from-policy --protector=/:#{protector_id} --policy=/:#{policy_id} --force --quiet"
      rescue CommandFail
        # Already removed (idempotent)
      end
      begin
        r "fscrypt metadata destroy --protector=/:#{protector_id} --force --quiet"
      rescue CommandFail
        # Already destroyed (idempotent)
      end
    end

    # Rename the "-rotate" protector back to the VM name.
    # fscrypt doesn't support rename, so we create a new protector with the
    # original name, link it to the policy, then remove the "-rotate" one.
    rotate_protector_id = find_protector_id_by_name(rotate_name)
    return unless rotate_protector_id

    key_file = File.join("", "tmp", "fscrypt-keepkey-#{vm_name}-#{$$}")
    begin
      File.open(key_file, "w", 0o600) { |f| f.write(keep_key_binary) }

      # Create protector with original VM name
      output = r "fscrypt metadata create protector / --source=raw_key --name=#{vm_name.shellescape} --key=#{key_file.shellescape} --quiet"
      new_protector_id = output.strip
      fail "Failed to create replacement protector" if new_protector_id.empty?

      # Link new protector to policy (authorize with rotate protector)
      r "fscrypt metadata add-protector-to-policy --protector=/:#{new_protector_id} --policy=/:#{policy_id} --unlock-with=/:#{rotate_protector_id} --key=#{key_file.shellescape} --quiet"

      # Remove rotate protector
      begin
        r "fscrypt metadata remove-protector-from-policy --protector=/:#{rotate_protector_id} --policy=/:#{policy_id} --force --quiet"
      rescue CommandFail
        # Already removed
      end
      begin
        r "fscrypt metadata destroy --protector=/:#{rotate_protector_id} --force --quiet"
      rescue CommandFail
        # Already destroyed
      end
    ensure
      FileUtils.rm_f(key_file)
    end
  end

  # Find the protector ID for a vm_name's primary protector (exact name match).
  def self.find_protector_id(vm_name)
    find_protector_id_by_name(vm_name) ||
      fail("Cannot find protector for #{vm_name}")
  end

  # Find the protector ID by exact name. Returns nil if not found.
  def self.find_protector_id_by_name(name)
    output = `fscrypt status / 2>&1`
    output.each_line do |line|
      if line.include?("\"#{name}\"")
        id = line.strip.split(/\s+/).first
        return id unless id.nil? || id.empty? || id == "PROTECTOR"
      end
    end
    nil
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
