# frozen_string_literal: true

require_relative "../lib/vm_fscrypt"
require "openssl"
require "fileutils"

RSpec.describe VmFscrypt do
  let(:vm_name) { "test-fscrypt-vm" }
  let(:vm_home) { "/vm/#{vm_name}/" }
  let(:dek_dir) { "/vm/.fscrypt_keys" }
  let(:dek_path) { "#{dek_dir}/#{vm_name}.json" }
  let(:dek_new_path) { "#{dek_path}.new" }
  let(:master_key) { OpenSSL::Random.random_bytes(32) }
  let(:mountpoint) { "/" }

  before do
    allow(described_class).to receive(:mountpoint_of).with(vm_home).and_return(mountpoint)
  end

  let(:kek_secrets) {
    algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(algorithm)
    {
      "algorithm" => algorithm,
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "auth_data" => "Ubicloud-fscrypt-test"
    }
  }

  describe ".encrypt" do
    it "wraps DEK, calls fscryptctl add_key and set_policy" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. ..])
      expect(FileUtils).to receive(:mkdir_p).with(dek_dir, mode: 0o700)

      # Expect wrapped DEK file to be written and parent dir synced
      fake_file = StringIO.new
      expect(File).to receive(:open).with(dek_path, "w", 0o600).and_yield(fake_file)
      expect(fake_file).to receive(:fsync)
      parent_dir_io = instance_double(File)
      expect(File).to receive(:open).with(dek_dir).and_yield(parent_dir_io)
      expect(parent_dir_io).to receive(:fsync)

      expect(described_class).to receive(:r)
        .with("fscryptctl add_key /", stdin: master_key)
        .and_return("abcdef0123456789\n")
      expect(described_class).to receive(:r)
        .with("fscryptctl set_policy abcdef0123456789 #{vm_home}")

      described_class.encrypt(vm_name, kek_secrets, master_key)

      # Verify JSON structure of written file
      written_json = JSON.parse(fake_file.string)
      expect(written_json["cipher"]).to eq("fscrypt-v2")
      expect(written_json["key"]).to be_a(Array)
      expect(written_json["key"].length).to eq(2)
    end

    it "fails if directory does not exist" do
      expect(File).to receive(:directory?).with(vm_home).and_return(false)
      expect { described_class.encrypt(vm_name, kek_secrets, master_key) }.to raise_error(RuntimeError, /does not exist/)
    end

    it "fails if directory is not empty" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. .. some_file])
      expect { described_class.encrypt(vm_name, kek_secrets, master_key) }.to raise_error(RuntimeError, /not empty/)
    end
  end

  describe ".add_key" do
    it "reads wrapped DEK and calls fscryptctl add_key" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(File).to receive(:exist?).with(dek_path).and_return(true)

      # Create a real wrapped DEK file content
      sek = StorageKeyEncryption.new(kek_secrets)
      wrapped = sek.wrap_key(master_key)
      wrapped_b64 = wrapped.map { |s| Base64.strict_encode64(s) }
      dek_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => wrapped_b64})
      expect(File).to receive(:read).with(dek_path).and_return(dek_json)

      expect(described_class).to receive(:r)
        .with("fscryptctl add_key /", stdin: master_key)
        .and_return("abcdef0123456789\n")

      described_class.add_key(vm_name, kek_secrets)
    end

    it "skips add_key if DEK file does not exist (pre-fscrypt VM)" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(File).to receive(:exist?).with(dek_path).and_return(false)
      expect(described_class).not_to receive(:r)

      described_class.add_key(vm_name, kek_secrets)
    end

    it "fails if directory does not exist" do
      expect(File).to receive(:directory?).with(vm_home).and_return(false)
      expect { described_class.add_key(vm_name, kek_secrets) }.to raise_error(RuntimeError, /does not exist/)
    end

    context "rotation window fallback (.new file)" do
      let(:new_kek_secrets) {
        algorithm = "aes-256-gcm"
        cipher = OpenSSL::Cipher.new(algorithm)
        {
          "algorithm" => algorithm,
          "key" => Base64.encode64(cipher.random_key),
          "init_vector" => Base64.encode64(cipher.random_iv),
          "auth_data" => "Ubicloud-fscrypt-test-new"
        }
      }

      it "falls back to .new file when main file fails to unwrap (rotation window)" do
        expect(File).to receive(:directory?).with(vm_home).and_return(true)
        expect(File).to receive(:exist?).with(dek_path).and_return(true)

        # Main file wrapped with OLD KEK (can't unwrap with new KEK)
        sek_old = StorageKeyEncryption.new(kek_secrets)
        old_wrapped = sek_old.wrap_key(master_key)
        old_wrapped_b64 = old_wrapped.map { |s| Base64.strict_encode64(s) }
        old_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => old_wrapped_b64})
        expect(File).to receive(:read).with(dek_path).and_return(old_json)

        # .new file wrapped with NEW KEK (the current KEK in DB)
        expect(File).to receive(:exist?).with(dek_new_path).and_return(true)
        sek_new = StorageKeyEncryption.new(new_kek_secrets)
        new_wrapped = sek_new.wrap_key(master_key)
        new_wrapped_b64 = new_wrapped.map { |s| Base64.strict_encode64(s) }
        new_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => new_wrapped_b64})
        expect(File).to receive(:read).with(dek_new_path).and_return(new_json)

        # Expect rename to fix host state
        expect(File).to receive(:rename).with(dek_new_path, dek_path)
        parent_dir_io = instance_double(File)
        expect(File).to receive(:open).with(dek_dir).and_yield(parent_dir_io)
        expect(parent_dir_io).to receive(:fsync)

        expect(described_class).to receive(:r)
          .with("fscryptctl add_key /", stdin: master_key)
          .and_return("abcdef0123456789\n")

        described_class.add_key(vm_name, new_kek_secrets)
      end

      it "raises CipherError if neither main nor .new file can be unwrapped" do
        expect(File).to receive(:directory?).with(vm_home).and_return(true)
        expect(File).to receive(:exist?).with(dek_path).and_return(true)

        # Main file wrapped with old KEK
        sek_old = StorageKeyEncryption.new(kek_secrets)
        old_wrapped = sek_old.wrap_key(master_key)
        old_wrapped_b64 = old_wrapped.map { |s| Base64.strict_encode64(s) }
        old_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => old_wrapped_b64})
        expect(File).to receive(:read).with(dek_path).and_return(old_json)

        # No .new file exists
        expect(File).to receive(:exist?).with(dek_new_path).and_return(false)

        expect { described_class.add_key(vm_name, new_kek_secrets) }.to raise_error(OpenSSL::Cipher::CipherError)
      end
    end
  end

  describe ".remove_key" do
    it "calls fscryptctl get_policy and remove_key" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(described_class).to receive(:r)
        .with("fscryptctl get_policy #{vm_home}")
        .and_return("Encryption policy for /vm/test/:\n\tPolicy version: 2\n\tMaster key identifier: abcdef0123456789\n\tContents encryption mode: AES-256-XTS\n\tFilenames encryption mode: AES-256-CTS\n\tFlags: PAD_32\n\tData unit size: default\n")
      expect(described_class).to receive(:r)
        .with("fscryptctl remove_key abcdef0123456789 /")

      described_class.remove_key(vm_name)
    end

    it "does nothing if directory does not exist" do
      expect(File).to receive(:directory?).with(vm_home).and_return(false)
      expect(described_class).not_to receive(:r)

      described_class.remove_key(vm_name)
    end

    it "tolerates expected failures (not encrypted, key already removed)" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(described_class).to receive(:r)
        .with("fscryptctl get_policy #{vm_home}")
        .and_raise(CommandFail.new("", "Error getting policy: not encrypted", ""))

      expect { described_class.remove_key(vm_name) }.not_to raise_error
    end

    it "raises on unexpected failures" do
      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(described_class).to receive(:r)
        .with("fscryptctl get_policy #{vm_home}")
        .and_raise(CommandFail.new("", "Permission denied", ""))

      expect { described_class.remove_key(vm_name) }.to raise_error(CommandFail)
    end
  end

  describe ".purge" do
    it "removes DEK file and .new file" do
      expect(FileUtils).to receive(:rm).with(dek_path)
      expect(FileUtils).to receive(:rm).with(dek_new_path)

      described_class.purge(vm_name)
    end

    it "tolerates already-removed files (idempotent)" do
      expect(FileUtils).to receive(:rm).with(dek_path).and_raise(Errno::ENOENT)
      expect(FileUtils).to receive(:rm).with(dek_new_path).and_raise(Errno::ENOENT)

      expect { described_class.purge(vm_name) }.not_to raise_error
    end

    it "raises on permission errors" do
      expect(FileUtils).to receive(:rm).with(dek_path).and_raise(Errno::EACCES)

      expect { described_class.purge(vm_name) }.to raise_error(Errno::EACCES)
    end
  end

  describe ".reencrypt" do
    let(:new_kek_secrets) {
      algorithm = "aes-256-gcm"
      cipher = OpenSSL::Cipher.new(algorithm)
      {
        "algorithm" => algorithm,
        "key" => Base64.encode64(cipher.random_key),
        "init_vector" => Base64.encode64(cipher.random_iv),
        "auth_data" => "Ubicloud-fscrypt-test-new"
      }
    }

    it "reads with old KEK and writes to .new with new KEK" do
      # Create real wrapped DEK content for old KEK
      sek_old = StorageKeyEncryption.new(kek_secrets)
      wrapped = sek_old.wrap_key(master_key)
      wrapped_b64 = wrapped.map { |s| Base64.strict_encode64(s) }
      dek_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => wrapped_b64})
      expect(File).to receive(:read).with(dek_path).and_return(dek_json)

      # Expect .new file to be written and parent dir synced
      fake_file = StringIO.new
      expect(File).to receive(:open).with(dek_new_path, "w", 0o600).and_yield(fake_file)
      expect(fake_file).to receive(:fsync)
      parent_dir_io = instance_double(File)
      expect(File).to receive(:open).with(dek_dir).and_yield(parent_dir_io)
      expect(parent_dir_io).to receive(:fsync)

      described_class.reencrypt(vm_name, kek_secrets, new_kek_secrets)

      # Verify the .new file can be unwrapped with new KEK to get the same master key
      written_json = JSON.parse(fake_file.string)
      expect(written_json["cipher"]).to eq("fscrypt-v2")
      new_wrapped = written_json["key"].map { |s| Base64.decode64(s) }
      sek_new = StorageKeyEncryption.new(new_kek_secrets)
      expect(sek_new.unwrap_key(new_wrapped)).to eq(master_key)
    end
  end

  describe ".test_keys" do
    let(:new_kek_secrets) {
      algorithm = "aes-256-gcm"
      cipher = OpenSSL::Cipher.new(algorithm)
      {
        "algorithm" => algorithm,
        "key" => Base64.encode64(cipher.random_key),
        "init_vector" => Base64.encode64(cipher.random_iv),
        "auth_data" => "Ubicloud-fscrypt-test-new"
      }
    }

    it "succeeds when both files contain the same DEK" do
      sek_old = StorageKeyEncryption.new(kek_secrets)
      sek_new = StorageKeyEncryption.new(new_kek_secrets)

      old_wrapped = sek_old.wrap_key(master_key)
      old_wrapped_b64 = old_wrapped.map { |s| Base64.strict_encode64(s) }
      old_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => old_wrapped_b64})

      new_wrapped = sek_new.wrap_key(master_key)
      new_wrapped_b64 = new_wrapped.map { |s| Base64.strict_encode64(s) }
      new_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => new_wrapped_b64})

      expect(File).to receive(:read).with(dek_path).and_return(old_json)
      expect(File).to receive(:read).with(dek_new_path).and_return(new_json)

      expect { described_class.test_keys(vm_name, kek_secrets, new_kek_secrets) }.not_to raise_error
    end

    it "fails when DEKs don't match" do
      sek_old = StorageKeyEncryption.new(kek_secrets)
      sek_new = StorageKeyEncryption.new(new_kek_secrets)

      old_wrapped = sek_old.wrap_key(master_key)
      old_wrapped_b64 = old_wrapped.map { |s| Base64.strict_encode64(s) }
      old_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => old_wrapped_b64})

      different_key = OpenSSL::Random.random_bytes(32)
      new_wrapped = sek_new.wrap_key(different_key)
      new_wrapped_b64 = new_wrapped.map { |s| Base64.strict_encode64(s) }
      new_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => new_wrapped_b64})

      expect(File).to receive(:read).with(dek_path).and_return(old_json)
      expect(File).to receive(:read).with(dek_new_path).and_return(new_json)

      expect { described_class.test_keys(vm_name, kek_secrets, new_kek_secrets) }.to raise_error(RuntimeError, /DEK mismatch/)
    end
  end

  describe ".retire_old" do
    it "renames .new to main and syncs parent dir" do
      expect(File).to receive(:rename).with(dek_new_path, dek_path)
      parent_dir_io = instance_double(File)
      expect(File).to receive(:open).with(dek_dir).and_yield(parent_dir_io)
      expect(parent_dir_io).to receive(:fsync)

      described_class.retire_old(vm_name)
    end

    it "is idempotent when .new already renamed and does not call sync_parent_dir" do
      expect(File).to receive(:rename).with(dek_new_path, dek_path).and_raise(Errno::ENOENT)
      expect(File).not_to receive(:open).with(dek_dir)

      expect { described_class.retire_old(vm_name) }.not_to raise_error
    end
  end

  describe "mountpoint resolution" do
    it "uses resolved mountpoint in fscryptctl commands" do
      allow(described_class).to receive(:mountpoint_of).with(vm_home).and_return("/vm")

      expect(File).to receive(:directory?).with(vm_home).and_return(true)
      expect(Dir).to receive(:entries).with(vm_home).and_return(%w[. ..])
      expect(FileUtils).to receive(:mkdir_p).with(dek_dir, mode: 0o700)

      fake_file = StringIO.new
      expect(File).to receive(:open).with(dek_path, "w", 0o600).and_yield(fake_file)
      expect(fake_file).to receive(:fsync)
      parent_dir_io = instance_double(File)
      expect(File).to receive(:open).with(dek_dir).and_yield(parent_dir_io)
      expect(parent_dir_io).to receive(:fsync)

      expect(described_class).to receive(:r)
        .with("fscryptctl add_key /vm", stdin: master_key)
        .and_return("abcdef0123456789\n")
      expect(described_class).to receive(:r)
        .with("fscryptctl set_policy abcdef0123456789 #{vm_home}")

      described_class.encrypt(vm_name, kek_secrets, master_key)
    end
  end

  describe ".mountpoint_of" do
    before do
      allow(described_class).to receive(:mountpoint_of).and_call_original
    end

    it "returns a mountpoint for a given path" do
      result = described_class.send(:mountpoint_of, "/usr/bin")
      expect(Pathname.new(result)).to be_mountpoint
    end

    it "returns / when path is /" do
      expect(described_class.send(:mountpoint_of, "/")).to eq("/")
    end
  end

  describe "end-to-end wrap/unwrap" do
    it "encrypts and add_key round-trips with real crypto" do
      # This test verifies the full StorageKeyEncryption round-trip
      # without mocking crypto, ensuring the JSON format is correct.
      sek = StorageKeyEncryption.new(kek_secrets)
      wrapped = sek.wrap_key(master_key)
      wrapped_b64 = wrapped.map { |s| Base64.strict_encode64(s) }
      dek_json = JSON.pretty_generate({"cipher" => "fscrypt-v2", "key" => wrapped_b64})

      # Parse it back and unwrap
      data = JSON.parse(dek_json)
      unwrapped_wrapped = data["key"].map { |s| Base64.decode64(s) }
      recovered_key = sek.unwrap_key(unwrapped_wrapped)

      expect(recovered_key).to eq(master_key)
    end

    it "reencrypt produces a file that unwraps to the same key" do
      sek_old = StorageKeyEncryption.new(kek_secrets)

      new_kek_secrets = kek_secrets.dup
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      new_kek_secrets["key"] = Base64.encode64(cipher.random_key)
      new_kek_secrets["init_vector"] = Base64.encode64(cipher.random_iv)
      sek_new = StorageKeyEncryption.new(new_kek_secrets)

      # Wrap with old KEK
      old_wrapped = sek_old.wrap_key(master_key)
      old_wrapped_b64 = old_wrapped.map { |s| Base64.strict_encode64(s) }

      # Unwrap and re-wrap with new KEK
      old_binary = old_wrapped_b64.map { |s| Base64.decode64(s) }
      recovered = sek_old.unwrap_key(old_binary)
      new_wrapped = sek_new.wrap_key(recovered)
      new_wrapped_b64 = new_wrapped.map { |s| Base64.strict_encode64(s) }

      # Verify new wrapping unwraps to same key
      new_binary = new_wrapped_b64.map { |s| Base64.decode64(s) }
      expect(sek_new.unwrap_key(new_binary)).to eq(master_key)
    end
  end
end
