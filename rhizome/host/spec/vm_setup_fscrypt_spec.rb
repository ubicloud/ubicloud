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
    it "removes orphaned protector metadata for both name variants" do
      status_output = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
        abc123def  No      Raw key protector "#{vm_name}"
        def456ghi  No      Raw key protector "#{vm_name}-rotate"
        xyz789ghi  No      Raw key protector "other-vm"
      STATUS
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return(status_output)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata destroy --protector=\/:abc123def --force --quiet/)
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata destroy --protector=\/:def456ghi --force --quiet/)

      VmSetupFscrypt.purge_metadata(vm_name)
    end

    it "does nothing if no protectors match" do
      allow(VmSetupFscrypt).to receive(:`).with(/fscrypt status/).and_return("No protectors\n")
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.purge_metadata(vm_name)
    end
  end

  describe ".parse_protector_table" do
    it "parses protector IDs and names from status output" do
      status_output = <<~STATUS
        PROTECTOR  LINKED     DESCRIPTION
        abc123def  Yes (/)    Raw key protector "#{vm_name}"
        xyz789ghi  No         Raw key protector "#{vm_name}-rotate"
      STATUS

      result = VmSetupFscrypt.parse_protector_table(status_output)
      expect(result).to eq([
        {id: "abc123def", name: vm_name},
        {id: "xyz789ghi", name: "#{vm_name}-rotate"}
      ])
    end

    it "returns empty array when no protectors found" do
      expect(VmSetupFscrypt.parse_protector_table("No protectors\n")).to eq([])
    end

    it "skips the header line" do
      status_output = <<~STATUS
        PROTECTOR  LINKED  DESCRIPTION
      STATUS

      expect(VmSetupFscrypt.parse_protector_table(status_output)).to eq([])
    end
  end

  describe ".add_protector" do
    let(:old_key) { OpenSSL::Random.random_bytes(32) }
    let(:new_key) { OpenSSL::Random.random_bytes(32) }

    before do
      allow(VmSetupFscrypt).to receive(:unlock)
    end

    # Helper to build dir_status with a protector table (policy-linked protectors)
    def dir_status_with(*protectors)
      lines = ["Policy:  abc123policy", "Unlocked: Yes", "PROTECTOR  LINKED     DESCRIPTION"]
      protectors.each do |id, name|
        lines << "#{id}  Yes (/)    Raw key protector \"#{name}\""
      end
      lines.join("\n") + "\n"
    end

    # Helper to build root_status (global protectors)
    def root_status_with(*protectors)
      lines = ["PROTECTOR  LINKED  DESCRIPTION"]
      protectors.each do |id, name|
        lines << "#{id}  No      Raw key protector \"#{name}\""
      end
      lines.join("\n") + "\n"
    end

    it "creates a new protector and links it to the policy (first rotation)" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["oldprot01", vm_name]))
      # No orphan to clean up
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1")
        .and_return(root_status_with(["oldprot01", vm_name]))

      allow(File).to receive(:open).with(%r{/tmp/fscrypt-newkey}, "w", 0o600).and_yield(StringIO.new)
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-oldkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata create protector.*--name=#{vm_name}-rotate/).and_return("newprot01\n")
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata add-protector-to-policy.*--protector=\/:newprot01.*--policy=\/:abc123policy.*--unlock-with=\/:oldprot01/)

      result = VmSetupFscrypt.add_protector(vm_name, old_key, new_key)
      expect(result).to eq("#{vm_name}-rotate")
    end

    it "creates vm_name protector when current is vm_name-rotate (second rotation)" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["rotprot01", "#{vm_name}-rotate"]))
      # No orphan
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1")
        .and_return(root_status_with(["rotprot01", "#{vm_name}-rotate"]))

      allow(File).to receive(:open).with(%r{/tmp/fscrypt-newkey}, "w", 0o600).and_yield(StringIO.new)
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-oldkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata create protector.*--name=#{Regexp.escape(vm_name)} /).and_return("newprot01\n")
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata add-protector-to-policy.*--protector=\/:newprot01.*--policy=\/:abc123policy.*--unlock-with=\/:rotprot01/)

      result = VmSetupFscrypt.add_protector(vm_name, old_key, new_key)
      expect(result).to eq(vm_name)
    end

    it "is idempotent when rotate protector already linked to policy" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      # Both protectors linked — add_protector already completed
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["oldprot01", vm_name], ["newprot01", "#{vm_name}-rotate"]))

      expect(VmSetupFscrypt).not_to receive(:r).with(/fscrypt metadata create/)

      result = VmSetupFscrypt.add_protector(vm_name, old_key, new_key)
      expect(result).to eq("#{vm_name}-rotate")
    end

    it "cleans up orphaned rotate protector and recreates (Bug 1 fix)" do
      # Dir status shows only the old protector linked (orphan not linked)
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["oldprot01", vm_name]))
      # Root status shows orphan exists globally
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status / 2>&1")
        .and_return(root_status_with(["oldprot01", vm_name], ["orphan01", "#{vm_name}-rotate"]))

      allow(File).to receive(:open).with(%r{/tmp/fscrypt-newkey}, "w", 0o600).and_yield(StringIO.new)
      allow(File).to receive(:open).with(%r{/tmp/fscrypt-oldkey}, "w", 0o600).and_yield(StringIO.new)
      allow(FileUtils).to receive(:rm_f)

      # Should destroy the orphan first
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata destroy --protector=\/:orphan01 --force --quiet/).ordered
      # Then create and link fresh
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata create protector.*--name=#{vm_name}-rotate/).and_return("newprot01\n").ordered
      expect(VmSetupFscrypt).to receive(:r).with(/fscrypt metadata add-protector-to-policy.*--protector=\/:newprot01/).ordered

      result = VmSetupFscrypt.add_protector(vm_name, old_key, new_key)
      expect(result).to eq("#{vm_name}-rotate")
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

    it "fails if no current protector found in policy" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      # Policy exists but no matching protector linked
      dir_status = "Policy:  abc123policy\nUnlocked: Yes\nPROTECTOR  LINKED  DESCRIPTION\nabc123  No  Raw key protector \"unrelated-vm\"\n"
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return(dir_status)

      expect { VmSetupFscrypt.add_protector(vm_name, old_key, new_key) }.to raise_error(RuntimeError, /Cannot find current protector/)
    end
  end

  describe ".remove_old_protectors" do
    # Helper to build dir_status with a protector table (policy-linked protectors)
    def dir_status_with(*protectors)
      lines = ["Policy:  abc123policy", "Unlocked: Yes", "PROTECTOR  LINKED     DESCRIPTION"]
      protectors.each do |id, name|
        lines << "#{id}  Yes (/)    Raw key protector \"#{name}\""
      end
      lines.join("\n") + "\n"
    end

    it "removes the old protector, keeps the rotate protector (no rename)" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["oldprot01", vm_name], ["newprot01", "#{vm_name}-rotate"]))

      # Should remove old protector (vm_name), keep rotate protector
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:oldprot01.*--policy=\/:abc123policy/)
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:oldprot01/)

      # Should NOT touch the rotate protector
      expect(VmSetupFscrypt).not_to receive(:r).with(/--protector=\/:newprot01/)

      VmSetupFscrypt.remove_old_protectors(vm_name, "#{vm_name}-rotate")
    end

    it "removes the rotate protector when keep_name is vm_name (second rotation)" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["rotprot01", "#{vm_name}-rotate"], ["newprot01", vm_name]))

      # Should remove rotate protector, keep vm_name protector
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:rotprot01.*--policy=\/:abc123policy/)
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:rotprot01/)

      # Should NOT touch the keep protector
      expect(VmSetupFscrypt).not_to receive(:r).with(/--protector=\/:newprot01/)

      VmSetupFscrypt.remove_old_protectors(vm_name, vm_name)
    end

    it "is idempotent when only keep_name protector remains (Bug 2 fix)" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      # Only the keep protector is linked — already cleaned up on a previous run
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["newprot01", "#{vm_name}-rotate"]))

      # Should NOT destroy anything
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.remove_old_protectors(vm_name, "#{vm_name}-rotate")
    end

    it "is idempotent on retry after full completion (Bug 2 regression test)" do
      # This is the exact scenario from Bug 2:
      # First run completed (old destroyed, no rename). Only keep protector remains.
      # Lost COMMIT causes retry. Must NOT destroy the remaining good protector.
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["newprot01", "#{vm_name}-rotate"]))

      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.remove_old_protectors(vm_name, "#{vm_name}-rotate")
    end

    it "does nothing if directory does not exist" do
      allow(File).to receive(:directory?).with(vm_home).and_return(false)
      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.remove_old_protectors(vm_name, "#{vm_name}-rotate")
    end

    it "does nothing if no policy found" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1").and_return("not encrypted\n")

      expect(VmSetupFscrypt).not_to receive(:r)

      VmSetupFscrypt.remove_old_protectors(vm_name, "#{vm_name}-rotate")
    end

    it "handles CommandFail when removing already-removed protectors" do
      allow(File).to receive(:directory?).with(vm_home).and_return(true)
      allow(VmSetupFscrypt).to receive(:`).with("fscrypt status #{vm_home} 2>&1")
        .and_return(dir_status_with(["oldprot01", vm_name], ["newprot01", "#{vm_name}-rotate"]))

      # Old protector removal fails (already removed/destroyed)
      expect(VmSetupFscrypt).to receive(:r).with(/remove-protector-from-policy.*--protector=\/:oldprot01/).and_raise(CommandFail.new("already removed", "", ""))
      expect(VmSetupFscrypt).to receive(:r).with(/metadata destroy.*--protector=\/:oldprot01/).and_raise(CommandFail.new("already destroyed", "", ""))

      expect { VmSetupFscrypt.remove_old_protectors(vm_name, "#{vm_name}-rotate") }.not_to raise_error
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
