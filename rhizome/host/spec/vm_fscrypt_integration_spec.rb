# frozen_string_literal: true

require_relative "../lib/vm_fscrypt"
require "openssl"
require "fileutils"
require "tmpdir"
require "open3"
require "pathname"
require "securerandom"

RSpec.describe "VmFscrypt integration" do
  def self.fscryptctl_available?
    system("which fscryptctl > /dev/null 2>&1")
  end

  def self.fscrypt_fs_available?
    return false unless fscryptctl_available?
    Dir.mktmpdir("fscrypt_check") do |tmpdir|
      mnt = Pathname.new(tmpdir)
      mnt = mnt.parent until mnt.mountpoint?
      mnt = mnt.to_s
      key = OpenSSL::Random.random_bytes(64)
      stdout, _, status = Open3.capture3("fscryptctl add_key #{mnt.shellescape}", stdin_data: key)
      if status.success?
        identifier = stdout.strip
        Open3.capture3("fscryptctl remove_key #{identifier} #{mnt.shellescape}")
        true
      else
        false
      end
    end
  rescue => e
    warn "fscrypt_fs_available? check failed: #{e.message}"
    false
  end

  let(:vm_name) { "integration-test-vm" }
  let(:kek_secrets) {
    algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(algorithm)
    {
      "algorithm" => algorithm,
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "auth_data" => "integration-test-#{vm_name}"
    }
  }
  let(:master_key) { OpenSSL::Random.random_bytes(64) }

  around do |example|
    Dir.mktmpdir("vm_fscrypt_integration") do |tmpdir|
      @tmpdir = tmpdir
      @dek_dir = File.join(tmpdir, ".fscrypt_keys")
      @vm_home = File.join(tmpdir, vm_name)
      FileUtils.mkdir_p(@dek_dir, mode: 0o700)
      FileUtils.mkdir_p(@vm_home)
      example.run
    end
  end

  before do
    stub_const("VmFscrypt::DEK_DIR", @dek_dir)
    vm_path_instance = instance_double(VmPath)
    allow(VmPath).to receive(:new).with(vm_name).and_return(vm_path_instance)
    allow(vm_path_instance).to receive(:home).with("").and_return(@vm_home)
  end

  def make_kek
    algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(algorithm)
    {
      "algorithm" => algorithm,
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "auth_data" => "integration-test-kek-#{SecureRandom.hex(4)}"
    }
  end

  # ==========================================================================
  # Layer 1: File I/O integration tests
  # No fscryptctl needed. Real files in tmpdir, real crypto.
  # ==========================================================================
  describe "Layer 1: file I/O" do
    describe "write_wrapped_dek and read_unwrapped_dek round-trip" do
      it "writes a wrapped DEK file to disk and reads it back unchanged" do
        dek_file = VmFscrypt.dek_path(vm_name)
        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)

        # Verify file exists with correct permissions
        expect(File.exist?(dek_file)).to be true
        stat = File.stat(dek_file)
        expect(stat.mode & 0o777).to eq(0o600)

        # Verify JSON structure
        data = JSON.parse(File.read(dek_file))
        expect(data["cipher"]).to eq("fscrypt-v2")
        expect(data["key"]).to be_a(Array)
        expect(data["key"].length).to eq(2) # [ciphertext, auth_tag]

        # Round-trip: unwrap must recover the original key
        recovered = VmFscrypt.send(:read_unwrapped_dek, dek_file, kek_secrets)
        expect(recovered).to eq(master_key)
      end

      it "fails to unwrap with a different KEK" do
        dek_file = VmFscrypt.dek_path(vm_name)
        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)

        wrong_kek = make_kek
        expect {
          VmFscrypt.send(:read_unwrapped_dek, dek_file, wrong_kek)
        }.to raise_error(OpenSSL::Cipher::CipherError)
      end

      it "handles 32-byte and 64-byte key sizes" do
        [32, 64].each do |size|
          key = OpenSSL::Random.random_bytes(size)
          dek_file = File.join(@dek_dir, "key-#{size}.json")
          VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, key)
          recovered = VmFscrypt.send(:read_unwrapped_dek, dek_file, kek_secrets)
          expect(recovered).to eq(key)
        end
      end
    end

    describe ".reencrypt with real files" do
      it "reads DEK wrapped with old KEK and writes .new wrapped with new KEK" do
        new_kek = make_kek

        # Write the original wrapped DEK
        dek_file = VmFscrypt.dek_path(vm_name)
        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)

        # Reencrypt with new KEK
        VmFscrypt.reencrypt(vm_name, kek_secrets, new_kek)

        # Verify .new file exists
        new_file = VmFscrypt.dek_new_path(vm_name)
        expect(File.exist?(new_file)).to be true

        # Verify .new file can be unwrapped with new KEK to the same master key
        recovered = VmFscrypt.send(:read_unwrapped_dek, new_file, new_kek)
        expect(recovered).to eq(master_key)

        # Verify original file still exists and can be unwrapped with old KEK
        original = VmFscrypt.send(:read_unwrapped_dek, dek_file, kek_secrets)
        expect(original).to eq(master_key)
      end
    end

    describe ".test_keys with real files" do
      it "succeeds when both files contain the same DEK" do
        new_kek = make_kek

        VmFscrypt.send(:write_wrapped_dek, VmFscrypt.dek_path(vm_name), kek_secrets, master_key)
        VmFscrypt.send(:write_wrapped_dek, VmFscrypt.dek_new_path(vm_name), new_kek, master_key)

        expect { VmFscrypt.test_keys(vm_name, kek_secrets, new_kek) }.not_to raise_error
      end

      it "fails when files contain different DEKs" do
        new_kek = make_kek

        VmFscrypt.send(:write_wrapped_dek, VmFscrypt.dek_path(vm_name), kek_secrets, master_key)
        VmFscrypt.send(:write_wrapped_dek, VmFscrypt.dek_new_path(vm_name), new_kek, OpenSSL::Random.random_bytes(64))

        expect { VmFscrypt.test_keys(vm_name, kek_secrets, new_kek) }.to raise_error(RuntimeError, /DEK mismatch/)
      end
    end

    describe ".retire_old with real files" do
      it "atomically renames .new to main" do
        new_kek = make_kek
        dek_file = VmFscrypt.dek_path(vm_name)
        new_file = VmFscrypt.dek_new_path(vm_name)

        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)
        VmFscrypt.send(:write_wrapped_dek, new_file, new_kek, master_key)

        VmFscrypt.retire_old(vm_name)

        # .new should be gone, main should exist with new KEK's content
        expect(File.exist?(new_file)).to be false
        expect(File.exist?(dek_file)).to be true

        # Main file should now be unwrappable with new KEK
        recovered = VmFscrypt.send(:read_unwrapped_dek, dek_file, new_kek)
        expect(recovered).to eq(master_key)
      end

      it "is idempotent when .new does not exist" do
        VmFscrypt.send(:write_wrapped_dek, VmFscrypt.dek_path(vm_name), kek_secrets, master_key)

        expect { VmFscrypt.retire_old(vm_name) }.not_to raise_error
        expect(File.exist?(VmFscrypt.dek_path(vm_name))).to be true
      end
    end

    describe ".purge with real files" do
      it "removes DEK file and .new file" do
        dek_file = VmFscrypt.dek_path(vm_name)
        new_file = VmFscrypt.dek_new_path(vm_name)

        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)
        File.write(new_file, "dummy .new content")

        VmFscrypt.purge(vm_name)

        expect(File.exist?(dek_file)).to be false
        expect(File.exist?(new_file)).to be false
      end

      it "is idempotent when files already removed" do
        expect { VmFscrypt.purge(vm_name) }.not_to raise_error
      end

      it "raises on permission errors", unless: Process.uid == 0 do
        dek_file = VmFscrypt.dek_path(vm_name)
        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)

        File.chmod(0o444, @dek_dir)
        begin
          expect { VmFscrypt.purge(vm_name) }.to raise_error(Errno::EACCES)
        ensure
          File.chmod(0o700, @dek_dir)
        end
      end
    end

    describe "full KEK rotation cycle" do
      it "rotates KEK end-to-end: reencrypt → test_keys → retire_old" do
        new_kek = make_kek
        dek_file = VmFscrypt.dek_path(vm_name)

        # Initial state: DEK wrapped with original KEK
        VmFscrypt.send(:write_wrapped_dek, dek_file, kek_secrets, master_key)

        # Phase 1: reencrypt
        VmFscrypt.reencrypt(vm_name, kek_secrets, new_kek)

        # Phase 2: test_keys
        expect { VmFscrypt.test_keys(vm_name, kek_secrets, new_kek) }.not_to raise_error

        # Phase 3: retire_old
        VmFscrypt.retire_old(vm_name)

        # Final: only new KEK works
        expect(File.exist?(VmFscrypt.dek_new_path(vm_name))).to be false
        expect(VmFscrypt.send(:read_unwrapped_dek, dek_file, new_kek)).to eq(master_key)
        expect {
          VmFscrypt.send(:read_unwrapped_dek, dek_file, kek_secrets)
        }.to raise_error(OpenSSL::Cipher::CipherError)
      end

      it "survives two consecutive rotations" do
        kek1 = kek_secrets
        kek2 = make_kek
        kek3 = make_kek
        dek_file = VmFscrypt.dek_path(vm_name)

        VmFscrypt.send(:write_wrapped_dek, dek_file, kek1, master_key)

        # Rotation 1: kek1 → kek2
        VmFscrypt.reencrypt(vm_name, kek1, kek2)
        VmFscrypt.test_keys(vm_name, kek1, kek2)
        VmFscrypt.retire_old(vm_name)

        # Rotation 2: kek2 → kek3
        VmFscrypt.reencrypt(vm_name, kek2, kek3)
        VmFscrypt.test_keys(vm_name, kek2, kek3)
        VmFscrypt.retire_old(vm_name)

        # Only kek3 works
        expect(VmFscrypt.send(:read_unwrapped_dek, dek_file, kek3)).to eq(master_key)
        expect { VmFscrypt.send(:read_unwrapped_dek, dek_file, kek1) }.to raise_error(OpenSSL::Cipher::CipherError)
        expect { VmFscrypt.send(:read_unwrapped_dek, dek_file, kek2) }.to raise_error(OpenSSL::Cipher::CipherError)
      end
    end

    describe "add_key rotation window fallback with real files" do
      it "falls back to .new file and completes rename when main file uses old KEK" do
        old_kek = kek_secrets
        new_kek = make_kek
        dek_file = VmFscrypt.dek_path(vm_name)
        new_file = VmFscrypt.dek_new_path(vm_name)

        # Simulate rotation window: main file wrapped with old KEK,
        # .new file wrapped with new (current) KEK
        VmFscrypt.send(:write_wrapped_dek, dek_file, old_kek, master_key)
        VmFscrypt.send(:write_wrapped_dek, new_file, new_kek, master_key)

        # add_key with new KEK: main file fails to unwrap, falls back to .new
        # Mock fscryptctl since this is a Layer 1 test
        expect(VmFscrypt).to receive(:r)
          .with(/fscryptctl add_key/, stdin: master_key)
          .and_return("abcdef0123456789\n")

        VmFscrypt.add_key(vm_name, new_kek)

        # Fallback should have renamed .new to main
        expect(File.exist?(new_file)).to be false
        expect(File.exist?(dek_file)).to be true

        # Main file should now be unwrappable with new KEK
        recovered = VmFscrypt.send(:read_unwrapped_dek, dek_file, new_kek)
        expect(recovered).to eq(master_key)
      end
    end
  end

  # ==========================================================================
  # Layer 2: fscryptctl integration tests
  # Requires: fscryptctl binary + ext4 with encryption support + kernel support
  # ==========================================================================
  layer2_available = fscryptctl_available? && fscrypt_fs_available?
  describe "Layer 2: fscryptctl", if: layer2_available do
    # Each test gets a fresh empty vm_home for fscryptctl set_policy
    # (policy can only be set on empty directories).
    before do
      FileUtils.rm_rf(@vm_home)
      FileUtils.mkdir_p(@vm_home)
    end

    it "encrypts an empty directory and sets fscrypt policy" do
      VmFscrypt.encrypt(vm_name, kek_secrets, master_key)

      # Verify policy was set
      policy_output = r("fscryptctl get_policy #{@vm_home.shellescape}")
      expect(policy_output).to include("Policy version:")
      expect(policy_output).to include("Master key identifier:")

      # Verify DEK file was written
      expect(File.exist?(VmFscrypt.dek_path(vm_name))).to be true

      # Write a file to the encrypted directory — kernel encrypts transparently
      test_file = File.join(@vm_home, "test.txt")
      File.write(test_file, "hello from fscrypt integration test")
      expect(File.read(test_file)).to eq("hello from fscrypt integration test")
    end

    it "add_key is idempotent (re-adding already-present key)" do
      VmFscrypt.encrypt(vm_name, kek_secrets, master_key)

      # add_key should succeed even though encrypt already added the key
      expect { VmFscrypt.add_key(vm_name, kek_secrets) }.not_to raise_error

      # Files in the encrypted directory should still be readable
      test_file = File.join(@vm_home, "test.txt")
      File.write(test_file, "idempotent add_key test")
      expect(File.read(test_file)).to eq("idempotent add_key test")
    end

    it "remove_key removes the key from the kernel keyring" do
      VmFscrypt.encrypt(vm_name, kek_secrets, master_key)

      # Write a file while key is present
      test_file = File.join(@vm_home, "test.txt")
      File.write(test_file, "before remove_key")

      VmFscrypt.remove_key(vm_name)

      # Re-add key so directory cleanup works and we can verify the file
      VmFscrypt.add_key(vm_name, kek_secrets)
      expect(File.read(test_file)).to eq("before remove_key")
    end

    it "remove_key tolerates unencrypted directories" do
      # vm_home has no policy set
      expect { VmFscrypt.remove_key(vm_name) }.not_to raise_error
    end

    it "purge cleans up DEK files after encryption" do
      VmFscrypt.encrypt(vm_name, kek_secrets, master_key)

      expect(File.exist?(VmFscrypt.dek_path(vm_name))).to be true

      VmFscrypt.purge(vm_name)

      expect(File.exist?(VmFscrypt.dek_path(vm_name))).to be false
      expect(File.exist?(VmFscrypt.dek_new_path(vm_name))).to be false
    end

    it "full lifecycle: encrypt → write → remove_key → add_key → read → purge" do
      # Encrypt
      VmFscrypt.encrypt(vm_name, kek_secrets, master_key)

      # Write test data
      test_file = File.join(@vm_home, "lifecycle.txt")
      File.write(test_file, "lifecycle test data")
      expect(File.read(test_file)).to eq("lifecycle test data")

      # Remove key
      VmFscrypt.remove_key(vm_name)

      # Re-add key from wrapped DEK on disk
      VmFscrypt.add_key(vm_name, kek_secrets)

      # Data should be recoverable
      expect(File.read(test_file)).to eq("lifecycle test data")

      # Purge DEK files
      VmFscrypt.purge(vm_name)
      expect(File.exist?(VmFscrypt.dek_path(vm_name))).to be false
    end

    it "KEK rotation works end-to-end with real fscryptctl" do
      new_kek = make_kek

      # Initial encryption
      VmFscrypt.encrypt(vm_name, kek_secrets, master_key)
      test_file = File.join(@vm_home, "rotation.txt")
      File.write(test_file, "survives rotation")

      # KEK rotation (no kernel ops — just re-wraps the DEK file)
      VmFscrypt.reencrypt(vm_name, kek_secrets, new_kek)
      VmFscrypt.test_keys(vm_name, kek_secrets, new_kek)
      VmFscrypt.retire_old(vm_name)

      # Remove and re-add key using new KEK
      VmFscrypt.remove_key(vm_name)
      VmFscrypt.add_key(vm_name, new_kek)

      # Data should still be readable
      expect(File.read(test_file)).to eq("survives rotation")
    end
  end
end
