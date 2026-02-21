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
end
