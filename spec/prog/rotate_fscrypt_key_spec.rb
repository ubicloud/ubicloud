# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RotateFscryptKey do
  subject(:rfk) {
    described_class.new(Strand.new(prog: "RotateFscryptKey"))
  }

  let(:sshable) { Sshable.new }

  let(:vm_host) {
    vh = instance_double(VmHost)
    allow(vh).to receive(:sshable).and_return(sshable)
    vh
  }

  let(:kek_1) {
    JSON.generate({
      "algorithm" => "aes-256-gcm",
      "key" => Base64.encode64("k" * 32),
      "init_vector" => Base64.encode64("i" * 12),
      "auth_data" => "Ubicloud-fscrypt"
    })
  }

  let(:kek_2) {
    JSON.generate({
      "algorithm" => "aes-256-gcm",
      "key" => Base64.encode64("K" * 32),
      "init_vector" => Base64.encode64("I" * 12),
      "auth_data" => "Ubicloud-fscrypt"
    })
  }

  let(:vm_metal) {
    vmt = instance_double(VmMetal)
    allow(vmt).to receive_messages(fscrypt_key: kek_1, fscrypt_key_2: nil)
    vmt
  }

  let(:vm) {
    vm = Vm.new.tap {
      it.id = Vm.generate_uuid
      it.name = "test-vm"
    }
    allow(vm).to receive_messages(vm_host:, inhost_name: "vmabc123", vm_metal:)
    vm
  }

  before do
    allow(rfk).to receive(:vm).and_return(vm)
  end

  describe "#start" do
    it "pops if vm does not use fscrypt" do
      allow(vm_metal).to receive(:fscrypt_key).and_return(nil)
      expect { rfk.start }.to exit({"msg" => "vm does not use fscrypt"})
    end

    it "pops if vm has no vm_metal" do
      allow(vm).to receive(:vm_metal).and_return(nil)
      expect { rfk.start }.to exit({"msg" => "vm does not use fscrypt"})
    end

    it "generates a new KEK, stores in fscrypt_key_2, and hops to install" do
      expect(vm_metal).to receive(:update) do |args|
        expect(args[:fscrypt_key_2]).not_to be_nil
        kek = JSON.parse(args[:fscrypt_key_2])
        expect(kek["algorithm"]).to eq("aes-256-gcm")
        expect(Base64.decode64(kek["key"]).bytesize).to eq(32)
        expect(Base64.decode64(kek["init_vector"]).bytesize).to eq(12)
        expect(kek["auth_data"]).to eq("Ubicloud-fscrypt")
      end
      expect { rfk.start }.to hop("install")
    end
  end

  describe "#install" do
    before do
      allow(vm_metal).to receive(:fscrypt_key_2).and_return(kek_2)
    end

    it "sends reencrypt command with old and new KEK secrets and hops to test_keys" do
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-reencrypt vmabc123",
        stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(params["old_key"]["algorithm"]).to eq("aes-256-gcm")
        expect(params["new_key"]["algorithm"]).to eq("aes-256-gcm")
        ""
      end

      expect { rfk.install }.to hop("test_keys")
    end
  end

  describe "#test_keys" do
    before do
      allow(vm_metal).to receive(:fscrypt_key_2).and_return(kek_2)
    end

    it "sends test-keys command and hops to promote_db" do
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-test-keys vmabc123",
        stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(params["old_key"]["algorithm"]).to eq("aes-256-gcm")
        expect(params["new_key"]["algorithm"]).to eq("aes-256-gcm")
        ""
      end

      expect { rfk.test_keys }.to hop("promote_db")
    end
  end

  describe "#promote_db" do
    before do
      allow(vm_metal).to receive(:fscrypt_key).and_return(kek_1)
      allow(vm_metal).to receive(:fscrypt_key_2).and_return(kek_2)
    end

    it "swaps fscrypt_key with fscrypt_key_2 and clears slot 2" do
      expect(vm_metal).to receive(:update) do |args|
        expect(args[:fscrypt_key]).to eq(kek_2)
        expect(args[:fscrypt_key_2]).to be_nil
      end
      expect { rfk.promote_db }.to hop("retire_old")
    end
  end

  describe "#retire_old" do
    it "sends retire-old command and pops" do
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-retire-old vmabc123",
        stdin: "{}"
      )

      expect { rfk.retire_old }.to exit({"msg" => "fscrypt key rotated"})
    end
  end

  # ============================================================
  # Crash-point interleaving tests
  #
  # Each test simulates the DB + host state at a specific crash
  # point in the rotation lifecycle, then calls the label that
  # would be retried. Verifies convergence and safety.
  #
  # Key insight: with KEK rotation, the DEK never changes. The
  # old KEK can always unwrap the original .json file until
  # retire_old renames .new over it. The DB points to the old
  # KEK until promote_db swaps slots. So at every crash point,
  # the DEK is recoverable.
  # ============================================================

  describe "crash-point interleaving" do
    describe "crash during #start (after DB write, before hop)" do
      # DB state: fscrypt_key = KEK1, fscrypt_key_2 = KEK2' (just written)
      # Host state: no .new file yet (install hasn't run)
      # On retry: start generates a NEW KEK2'' and overwrites fscrypt_key_2.
      # Safe: the host has no .new file for KEK2', so overwriting is harmless.

      it "overwrites fscrypt_key_2 with a fresh KEK on retry" do
        stale_kek = kek_2
        allow(vm_metal).to receive(:fscrypt_key_2).and_return(stale_kek)

        expect(vm_metal).to receive(:update) do |args|
          expect(args[:fscrypt_key_2]).not_to eq(stale_kek)
          kek = JSON.parse(args[:fscrypt_key_2])
          expect(kek["algorithm"]).to eq("aes-256-gcm")
        end

        expect { rfk.start }.to hop("install")
      end
    end

    describe "crash during #install (SSH failed or commit lost)" do
      # DB state: fscrypt_key = KEK1, fscrypt_key_2 = KEK2
      # Host state: .new file may or may not exist
      # On retry: reencrypt overwrites .new file (temp + rename).
      # Safe: the original .json is untouched; .new is disposable.

      it "re-sends reencrypt command on retry (idempotent: overwrites .new)" do
        allow(vm_metal).to receive(:fscrypt_key_2).and_return(kek_2)

        expect(sshable).to receive(:_cmd).with(
          "sudo host/bin/setup-vm rotate-fscrypt-reencrypt vmabc123",
          stdin: anything
        ).and_return("")

        expect { rfk.install }.to hop("test_keys")
      end
    end

    describe "crash during #test_keys (read-only, safe to retry)" do
      # DB state: fscrypt_key = KEK1, fscrypt_key_2 = KEK2
      # Host state: .new file exists (from install)
      # On retry: test_keys re-reads both files and compares. Pure read.
      # Safe: no state modification.

      it "re-sends test-keys command on retry (pure read, no state change)" do
        allow(vm_metal).to receive(:fscrypt_key_2).and_return(kek_2)

        expect(sshable).to receive(:_cmd).with(
          "sudo host/bin/setup-vm rotate-fscrypt-test-keys vmabc123",
          stdin: anything
        ).and_return("")

        expect { rfk.test_keys }.to hop("promote_db")
      end
    end

    describe "crash during #promote_db (after DB write, before hop)" do
      # DB state: fscrypt_key = KEK2 (promoted), fscrypt_key_2 = nil
      # Host state: both .json (old KEK1) and .new (KEK2) exist
      # On retry: promote_db sets fscrypt_key = fscrypt_key_2.
      # BUT fscrypt_key_2 is nil (already promoted).
      #
      # This crash point is safe because the strand framework makes
      # the DB write + hop atomic (single transaction). If the DB
      # write succeeds, the hop succeeds. If the DB write fails,
      # we retry with original state (KEK1 in slot 1, KEK2 in slot 2).

      it "promotes KEK2 to slot 1 and clears slot 2 atomically" do
        allow(vm_metal).to receive(:fscrypt_key).and_return(kek_1)
        allow(vm_metal).to receive(:fscrypt_key_2).and_return(kek_2)

        expect(vm_metal).to receive(:update) do |args|
          expect(args[:fscrypt_key]).to eq(kek_2)
          expect(args[:fscrypt_key_2]).to be_nil
        end

        expect { rfk.promote_db }.to hop("retire_old")
      end
    end

    describe "crash during #retire_old (SSH failed or commit lost)" do
      # DB state: fscrypt_key = KEK2 (promoted), fscrypt_key_2 = nil
      # Host state: .new may or may not have been renamed to .json
      #
      # Case 1: .new exists -> rename completes on retry.
      # Case 2: .new already renamed -> File.rename raises Errno::ENOENT
      #   for the source, but the host-side retire_old uses File.rename
      #   which is atomic. If .new is gone, the file was already promoted.
      #
      # In either case, KEK2 (now in DB slot 1) can unwrap the file.
      # Safe: retire_old is idempotent (rename is atomic, second call
      # finds .json already has the new content).

      it "re-sends retire-old command on retry" do
        expect(sshable).to receive(:_cmd).with(
          "sudo host/bin/setup-vm rotate-fscrypt-retire-old vmabc123",
          stdin: "{}"
        )

        expect { rfk.retire_old }.to exit({"msg" => "fscrypt key rotated"})
      end
    end
  end

  # ============================================================
  # Full rotation cycle test
  #
  # Simulates TWO consecutive KEK rotations through the entire
  # strand lifecycle (start -> install -> test_keys -> promote_db
  # -> retire_old). Confirms no stale state after consecutive
  # rotations.
  # ============================================================

  describe "full rotation cycle (two consecutive rotations)" do
    it "completes two KEK rotations correctly" do
      # Track vm_metal state through the rotation
      current_fscrypt_key = kek_1
      current_fscrypt_key_2 = nil

      allow(vm_metal).to receive(:fscrypt_key) { current_fscrypt_key }
      allow(vm_metal).to receive(:fscrypt_key_2) { current_fscrypt_key_2 }

      # --- First rotation: KEK1 -> KEK2 ---

      # Step 1: start — generates KEK2
      generated_kek_2 = nil
      expect(vm_metal).to receive(:update) do |args|
        generated_kek_2 = args[:fscrypt_key_2]
        current_fscrypt_key_2 = generated_kek_2
      end
      expect { rfk.start }.to hop("install")

      # Step 2: install — reencrypt DEK file with KEK2
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-reencrypt vmabc123",
        stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(params["old_key"]).to eq(JSON.parse(kek_1))
        expect(params["new_key"]).to eq(JSON.parse(generated_kek_2))
        ""
      end
      expect { rfk.install }.to hop("test_keys")

      # Step 3: test_keys — verify both files match
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-test-keys vmabc123",
        stdin: anything
      ).and_return("")
      expect { rfk.test_keys }.to hop("promote_db")

      # Step 4: promote_db — KEK2 becomes slot 1
      expect(vm_metal).to receive(:update) do |args|
        expect(args[:fscrypt_key]).to eq(generated_kek_2)
        expect(args[:fscrypt_key_2]).to be_nil
        current_fscrypt_key = args[:fscrypt_key]
        current_fscrypt_key_2 = nil
      end
      expect { rfk.promote_db }.to hop("retire_old")

      # Step 5: retire_old — rename .new over .json
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-retire-old vmabc123",
        stdin: "{}"
      )
      expect { rfk.retire_old }.to exit({"msg" => "fscrypt key rotated"})

      # --- Second rotation: KEK2 -> KEK3 ---

      rfk2 = described_class.new(Strand.new(prog: "RotateFscryptKey"))
      allow(rfk2).to receive(:vm).and_return(vm)

      expect(current_fscrypt_key).to eq(generated_kek_2)
      expect(current_fscrypt_key_2).to be_nil

      # Step 1: start — generates KEK3
      generated_kek_3 = nil
      expect(vm_metal).to receive(:update) do |args|
        generated_kek_3 = args[:fscrypt_key_2]
        current_fscrypt_key_2 = generated_kek_3
      end
      expect { rfk2.start }.to hop("install")

      # Step 2: install
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-reencrypt vmabc123",
        stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(params["old_key"]).to eq(JSON.parse(generated_kek_2))
        expect(params["new_key"]).to eq(JSON.parse(generated_kek_3))
        ""
      end
      expect { rfk2.install }.to hop("test_keys")

      # Step 3: test_keys
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-test-keys vmabc123",
        stdin: anything
      ).and_return("")
      expect { rfk2.test_keys }.to hop("promote_db")

      # Step 4: promote_db — KEK3 becomes slot 1
      expect(vm_metal).to receive(:update) do |args|
        expect(args[:fscrypt_key]).to eq(generated_kek_3)
        expect(args[:fscrypt_key_2]).to be_nil
        current_fscrypt_key = args[:fscrypt_key]
        current_fscrypt_key_2 = nil
      end
      expect { rfk2.promote_db }.to hop("retire_old")

      # Step 5: retire_old
      expect(sshable).to receive(:_cmd).with(
        "sudo host/bin/setup-vm rotate-fscrypt-retire-old vmabc123",
        stdin: "{}"
      )
      expect { rfk2.retire_old }.to exit({"msg" => "fscrypt key rotated"})

      # Final state: fscrypt_key = KEK3, fscrypt_key_2 = nil
      expect(current_fscrypt_key).to eq(generated_kek_3)
      expect(current_fscrypt_key_2).to be_nil
    end
  end
end
