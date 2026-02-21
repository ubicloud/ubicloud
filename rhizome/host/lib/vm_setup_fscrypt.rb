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
  #
  # Uses alternating protector names (vm_name <-> vm_name-rotate) to avoid
  # the rename step that caused Bug 2 (name ambiguity on retry).
  #
  # Returns the rotate_name used for the new protector (caller must pass this
  # to remove_old_protectors as keep_name).
  #
  # Idempotent: if the rotate protector is already linked to the policy, returns
  # its name immediately. If it exists globally but is not linked (orphan from
  # a crash between create and link), destroys the orphan and recreates.
  def self.add_protector(vm_name, old_key_binary, new_key_binary)
    vm_home = File.join("", "vm", vm_name)
    fail "Directory does not exist: #{vm_home}" unless File.directory?(vm_home)

    # Ensure directory is unlocked (needed to add protector to policy)
    unlock(vm_name, old_key_binary)

    # Get policy ID and linked protectors from directory status.
    # fscrypt status <dir> shows ONLY protectors linked to this directory's
    # policy, unlike fscrypt status / which shows ALL protectors globally.
    dir_status = `fscrypt status #{vm_home.shellescape} 2>&1`
    policy_id = dir_status[/Policy:\s+(\w+)/, 1]
    fail "Cannot find fscrypt policy for #{vm_home}" unless policy_id

    linked = parse_protector_table(dir_status)

    # Determine the current protector and compute the alternate name.
    # Alternation: "vm_name" <-> "vm_name-rotate"
    current = linked.find { |p| p[:name] == vm_name || p[:name] == "#{vm_name}-rotate" }
    fail "Cannot find current protector for #{vm_name} in policy" unless current
    rotate_name = (current[:name] == vm_name) ? "#{vm_name}-rotate" : vm_name

    # Idempotent: if rotate protector is already linked to the policy, done.
    if linked.any? { |p| p[:name] == rotate_name }
      return rotate_name
    end

    # Clean up orphaned rotate protector (exists globally but not linked to
    # the policy — crash between "create protector" and "add-protector-to-policy").
    orphan_id = find_protector_id_by_name(rotate_name)
    if orphan_id
      begin
        r "fscrypt metadata destroy --protector=/:#{orphan_id} --force --quiet"
      rescue CommandFail
      end
    end

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
      r "fscrypt metadata add-protector-to-policy --protector=/:#{new_protector_id} --policy=/:#{policy_id} --unlock-with=/:#{current[:id]} --key=#{old_key_file.shellescape} --quiet"
    ensure
      FileUtils.rm_f(new_key_file)
      FileUtils.rm_f(old_key_file)
    end

    rotate_name
  end

  # Remove all protectors linked to the directory's policy except the one
  # named keep_name (the protector holding the now-active key after DB promotion).
  #
  # No rename step — protector names alternate between vm_name and
  # vm_name-rotate across rotations, so the destroy target always has a
  # different name from the keep target. This eliminates the name ambiguity
  # that caused Bug 2 (retry destroying the renamed good protector).
  #
  # Idempotent: if only one protector is linked (matching keep_name), returns
  # immediately. Tolerates already-removed protectors.
  def self.remove_old_protectors(vm_name, keep_name)
    vm_home = File.join("", "vm", vm_name)
    return unless File.directory?(vm_home)

    dir_status = `fscrypt status #{vm_home.shellescape} 2>&1`
    policy_id = dir_status[/Policy:\s+(\w+)/, 1]
    return unless policy_id

    linked = parse_protector_table(dir_status)

    # Destroy all linked protectors that are NOT the keep_name protector.
    linked.each do |prot|
      next if prot[:name] == keep_name
      begin
        r "fscrypt metadata remove-protector-from-policy --protector=/:#{prot[:id]} --policy=/:#{policy_id} --force --quiet"
      rescue CommandFail
        # Already removed from policy (idempotent)
      end
      begin
        r "fscrypt metadata destroy --protector=/:#{prot[:id]} --force --quiet"
      rescue CommandFail
        # Already destroyed (idempotent)
      end
    end
  end

  # Find the protector ID for a vm_name's primary protector (exact name match).
  def self.find_protector_id(vm_name)
    find_protector_id_by_name(vm_name) ||
      fail("Cannot find protector for #{vm_name}")
  end

  # Find the protector ID by exact name from global protector list.
  # Returns nil if not found.
  def self.find_protector_id_by_name(name)
    output = `fscrypt status / 2>&1`
    parse_protector_table(output).each do |prot|
      return prot[:id] if prot[:name] == name
    end
    nil
  end

  # Parse the protector table from fscrypt status output.
  # Returns array of {id:, name:} hashes.
  # Works for both "fscrypt status /" (global) and "fscrypt status <dir>" (policy-linked).
  #
  # Example input lines:
  #   PROTECTOR  LINKED     DESCRIPTION
  #   abc123def  Yes (/)    Raw key protector "vm_name"
  #   xyz789ghi  No         Raw key protector "vm_name-rotate"
  def self.parse_protector_table(status_output)
    protectors = []
    status_output.each_line do |line|
      # Match lines with a quoted protector name
      if (match = line.match(/\A\s*(\w+)\s+.*"([^"]+)"/))
        id, name = match[1], match[2]
        next if id == "PROTECTOR"
        protectors << {id: id, name: name}
      end
    end
    protectors
  end

  # Clean up orphaned fscrypt metadata (policy and protector) after deleting
  # the encrypted directory. Call this after deluser --remove-home.
  def self.purge_metadata(vm_name)
    output = `fscrypt status / 2>&1`
    parse_protector_table(output).each do |prot|
      # Match both "vm_name" and "vm_name-rotate" protectors
      next unless prot[:name] == vm_name || prot[:name] == "#{vm_name}-rotate"
      begin
        r "fscrypt metadata destroy --protector=/:#{prot[:id]} --force --quiet"
      rescue CommandFail
        # Ignore cleanup failures
      end
    end
  end
end
