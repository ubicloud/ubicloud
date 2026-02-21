# frozen_string_literal: true

require_relative "../lib/vm_setup_fscrypt"
require "openssl"
require "fileutils"

RSpec.describe VmSetupFscrypt do
  let(:vm_name) { "test-fscrypt-vm" }
  let(:vm_home) { "/vm/#{vm_name}" }
  let(:key_binary) { OpenSSL::Random.random_bytes(32) }

  describe ".encrypt" do
    it "encrypts an empty directory with fscrypt" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. ..])
      expect(File).to receive(:open).with(%r{/tmp/fscrypt-key-#{vm_name}}, "w", 0o600).and_yield(StringIO.new)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt encrypt #{Regexp.escape(vm_home)}.*--source=raw_key.*--name=#{vm_name}.*--key=.*--quiet/)
      expect(FileUtils).to receive(:rm_f).with(%r{/tmp/fscrypt-key-#{vm_name}})

      VmSetupFscrypt.encrypt(vm_name, key_binary)
    end

    it "fails if directory does not exist" do
      expect(File).to receive(:directory?).with(vm_home).and_return(false)
      expect { VmSetupFscrypt.encrypt(vm_name, key_binary) }.to raise_error(RuntimeError, /does not exist/)
    end

    it "fails if directory is not empty" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. .. some_file])
      expect { VmSetupFscrypt.encrypt(vm_name, key_binary) }.to raise_error(RuntimeError, /not empty/)
    end
  end

  describe ".unlock" do
    it "unlocks a locked fscrypt directory" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. ..])
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return("Encrypted: true\nUnlocked: No")
      expect(File).to receive(:open).with(%r{/tmp/fscrypt-key-#{vm_name}}, "w", 0o600).and_yield(StringIO.new)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt unlock #{Regexp.escape(vm_home)}.*--key=.*--quiet/)
      expect(FileUtils).to receive(:rm_f).with(%r{/tmp/fscrypt-key-#{vm_name}})

      VmSetupFscrypt.unlock(vm_name, key_binary)
    end

    it "skips unlock if already unlocked" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. .. some_file])
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return("Unlocked: Yes")
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.unlock(vm_name, key_binary)
    end

    it "skips unlock if directory is not an fscrypt directory" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. .. some_file])
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return("not encrypted")
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.unlock(vm_name, key_binary)
    end

    it "unlocks when Dir.entries raises ENOKEY (locked directory)" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_raise(Errno::ENOKEY)
      expect(File).to receive(:open).with(%r{/tmp/fscrypt-key-#{vm_name}}, "w", 0o600).and_yield(StringIO.new)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt unlock #{Regexp.escape(vm_home)}.*--key=.*--quiet/)
      expect(FileUtils).to receive(:rm_f).with(%r{/tmp/fscrypt-key-#{vm_name}})

      VmSetupFscrypt.unlock(vm_name, key_binary)
    end

    it "fails if directory does not exist" do
      expect(File).to receive(:directory?).with(vm_home).and_return(false)
      expect { VmSetupFscrypt.unlock(vm_name, key_binary) }.to raise_error(RuntimeError, /does not exist/)
    end
  end

  describe ".lock" do
    it "locks an fscrypt directory" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt lock #{Regexp.escape(vm_home)}.*--quiet/)

      VmSetupFscrypt.lock(vm_name)
    end

    it "does nothing if directory does not exist" do
      expect(File).to receive(:directory?).with(vm_home).and_return(false)
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.lock(vm_name)
    end

    it "ignores lock failures" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(VmSetupFscrypt).to receive(:r).and_raise(CommandFail.new("lock failed", "", "lock error"))

      expect { VmSetupFscrypt.lock(vm_name) }.not_to raise_error
    end
  end

  describe ".purge_metadata" do
    it "removes orphaned protector metadata" do
      status_output = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        abc123def  No      Raw key protector "#{vm_name}"
        xyz789ghi  No      Raw key protector "other-vm"
      STATUS
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return(status_output)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata destroy --protector=\/:abc123def --force --quiet/)

      VmSetupFscrypt.purge_metadata(vm_name)
    end

    it "does nothing if no protectors match" do
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return("No protectors\n")
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.purge_metadata(vm_name)
    end
  end

  describe ".add_protector" do
    let(:old_key) { OpenSSL::Random.random_bytes(32) }
    let(:new_key) { OpenSSL::Random.random_bytes(32) }
    let(:dir_status) { "Policy:  abc123policy\nUnlocked: Yes\n" }
    let(:root_status_no_rotate) {
      <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        oldprot01  No      Raw key protector "#{vm_name}"
      STATUS
    }

    before do
      # Stub unlock (called internally by add_protector)
      allow(VmSetupFscrypt).to receive(:unlock)
    end

    it "creates a new protector and links it to the policy" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      # Use exact command strings instead of regexes to avoid overlap
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return(dir_status)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1").and_return(root_status_no_rotate)

      # Key file writes
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-newkey}, "w", 0o600).and_yield(StringIO.new)
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-oldkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata create protector.*--name=#{vm_name}-rotate/).and_return("newprot01\n")
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata add-protector-to-policy.*--protector=\/:newprot01.*--policy=\/:abc123policy.*--unlock-with=\/:oldprot01/)

      VmSetupFscrypt.add_protector(vm_name, old_key, new_key)
    end

    it "is idempotent when rotate protector already exists" do
      root_status_with_rotate = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        oldprot01  No      Raw key protector "#{vm_name}"
        newprot01  No      Raw key protector "#{vm_name}-rotate"
      STATUS
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return(dir_status)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1").and_return(root_status_with_rotate)

      expect(VmSetupFscrypt).not_to receive(:r).with(/fscrypt metadata create/)

      VmSetupFscrypt.add_protector(vm_name, old_key, new_key)
    end

    it "fails if directory does not exist" do
      allow(File).to receive(:directory?).with(vm_home).and_return(false)

      expect { VmSetupFscrypt.add_protector(vm_name, old_key, new_key) }.to raise_error(RuntimeError, /does not exist/)
    end

    it "fails if policy cannot be found" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return("not encrypted\n")

      expect { VmSetupFscrypt.add_protector(vm_name, old_key, new_key) }.to raise_error(RuntimeError, /Cannot find fscrypt policy/)
    end
  end

  describe ".remove_old_protectors" do
    let(:keep_key) { OpenSSL::Random.random_bytes(32) }
    let(:dir_status) { "Policy:  abc123policy\nUnlocked: Yes\n" }

    it "removes the old protector and renames rotate protector" do
      root_status = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        oldprot01  No      Raw key protector "#{vm_name}"
        newprot01  No      Raw key protector "#{vm_name}-rotate"
      STATUS
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return(dir_status)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1").and_return(root_status)

      # Remove old protector from policy and destroy it
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:oldprot01.*--policy=\/:abc123policy/).ordered
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:oldprot01/).ordered

      # Rename: find rotate protector, create new one with original name, link, then remove rotate
      allow(VmSetupFscrypt).to receive(:find_protector_id_by_name).with("#{vm_name}-rotate").and_return("newprot01")
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-keepkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      expect(VmSetupFscrypt).to receive(:r).with(/metadata create protector.*--name=#{Regexp.escape(vm_name)} /).and_return("renprot01\n").ordered
      expect(VmSetupFscrypt).to receive(:r).with(/add-protector-to-policy.*--protector=\/:renprot01.*--unlock-with=\/:newprot01/).ordered
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:newprot01/).ordered
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:newprot01/).ordered

      VmSetupFscrypt.remove_old_protectors(vm_name, keep_key)
    end

    it "is idempotent when old protector already removed" do
      root_status = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        newprot01  No      Raw key protector "#{vm_name}-rotate"
      STATUS
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return(dir_status)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1").and_return(root_status)

      # No old protector to remove, just rename
      allow(VmSetupFscrypt).to receive(:find_protector_id_by_name).with("#{vm_name}-rotate").and_return("newprot01")
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-keepkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      expect(VmSetupFscrypt).to receive(:r).with(/metadata create protector.*--name=#{Regexp.escape(vm_name)} /).and_return("renprot01\n")
      expect(VmSetupFscrypt).to receive(:r).with(/add-protector-to-policy.*--protector=\/:renprot01.*--unlock-with=\/:newprot01/)
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:newprot01/)
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:newprot01/)

      VmSetupFscrypt.remove_old_protectors(vm_name, keep_key)
    end

    it "does nothing if directory does not exist" do
      allow(File).to receive(:directory?).with(vm_home).and_return(false)
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.remove_old_protectors(vm_name, keep_key)
    end

    it "does nothing if no policy found" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return("not encrypted\n")

      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.remove_old_protectors(vm_name, keep_key)
    end

    it "handles CommandFail when removing already-removed protectors" do
      root_status = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        oldprot01  No      Raw key protector "#{vm_name}"
        newprot01  No      Raw key protector "#{vm_name}-rotate"
      STATUS
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return(dir_status)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1").and_return(root_status)

      # Old protector removal fails (already removed)
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:oldprot01/).and_raise(CommandFail.new("already removed", "", ""))
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:oldprot01/).and_raise(CommandFail.new("already destroyed", "", ""))

      # Rename still works
      allow(VmSetupFscrypt).to receive(:find_protector_id_by_name).with("#{vm_name}-rotate").and_return("newprot01")
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-keepkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      expect(VmSetupFscrypt).to receive(:r).with(/metadata create protector.*--name=#{Regexp.escape(vm_name)} /).and_return("renprot01\n")
      expect(VmSetupFscrypt).to receive(:r).with(/add-protector-to-policy.*--protector=\/:renprot01.*--unlock-with=\/:newprot01/)
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:newprot01/)
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:newprot01/)

      expect { VmSetupFscrypt.remove_old_protectors(vm_name, keep_key) }.not_to raise_error
    end
  end

  describe ".find_protector_id" do
    it "finds the protector ID for a vm_name" do
      status_output = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        abc123def  No      Raw key protector "#{vm_name}"
        xyz789ghi  No      Raw key protector "other-vm"
      STATUS
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status \//).and_return(status_output)

      expect(VmSetupFscrypt.find_protector_id(vm_name)).to eq("abc123def")
    end

    it "raises if protector not found" do
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status \//).and_return("No protectors\n")

      expect { VmSetupFscrypt.find_protector_id(vm_name) }.to raise_error(RuntimeError, /Cannot find protector/)
    end
  end

  describe ".find_protector_id_by_name" do
    it "returns protector ID for exact name match" do
      status_output = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        abc123def  No      Raw key protector "#{vm_name}"
      STATUS
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status \//).and_return(status_output)

      expect(VmSetupFscrypt.find_protector_id_by_name(vm_name)).to eq("abc123def")
    end

    it "returns nil if name not found" do
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status \//).and_return("No protectors\n")

      expect(VmSetupFscrypt.find_protector_id_by_name(vm_name)).to be_nil
    end
  end
end
