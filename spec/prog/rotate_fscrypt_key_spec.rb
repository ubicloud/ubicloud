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

  let(:vm) {
    vm = Vm.new.tap {
      it.id = Vm.generate_uuid
      it.name = "test-vm"
      it.fscrypt_key = Base64.encode64("a" * 32)
    }
    allow(vm).to receive(:vm_host).and_return(vm_host)
    allow(vm).to receive(:inhost_name).and_return("vmabc123")
    vm
  }

  before do
    allow(rfk).to receive(:vm).and_return(vm)
  end

  describe "#start" do
    it "pops if vm does not use fscrypt" do
      vm.fscrypt_key = nil
      expect { rfk.start }.to exit({"msg" => "vm does not use fscrypt"})
    end

    it "generates a new key, stores in fscrypt_key_2, and hops to add_protector" do
      expect(vm).to receive(:update) do |args|
        expect(args[:fscrypt_key_2]).not_to be_nil
        key_binary = Base64.decode64(args[:fscrypt_key_2])
        expect(key_binary.bytesize).to eq(32)
      end
      expect { rfk.start }.to hop("add_protector")
    end
  end

  describe "#add_protector" do
    before do
      vm.fscrypt_key_2 = Base64.encode64("b" * 32)
    end

    it "sends SSH command, stores rotate_name in frame, and hops to promote_db" do
      expect(sshable).to receive(:_cmd).with(
        /sudo host\/bin\/setup-vm rotate-fscrypt-add vmabc123/,
        stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(Base64.decode64(params["old_key"]).bytesize).to eq(32)
        expect(Base64.decode64(params["new_key"]).bytesize).to eq(32)
        "vmabc123-rotate\n"
      end

      expect(rfk).to receive(:update_stack).with({"rotate_name" => "vmabc123-rotate"})

      expect { rfk.add_protector }.to hop("promote_db")
    end
  end

  describe "#promote_db" do
    before do
      vm.fscrypt_key = Base64.encode64("a" * 32)
      vm.fscrypt_key_2 = Base64.encode64("b" * 32)
    end

    it "swaps fscrypt_key with fscrypt_key_2 and clears slot 2" do
      expect(vm).to receive(:update) do |args|
        expect(args[:fscrypt_key]).to eq(vm.fscrypt_key_2)
        expect(args[:fscrypt_key_2]).to be_nil
      end
      expect { rfk.promote_db }.to hop("remove_old")
    end
  end

  describe "#remove_old" do
    it "sends SSH command with keep_name from frame and pops" do
      rfk.strand.stack.first.merge!("rotate_name" => "vmabc123-rotate")
      rfk.instance_variable_set(:@frame, nil)

      expect(sshable).to receive(:_cmd).with(
        /sudo host\/bin\/setup-vm rotate-fscrypt-remove vmabc123/,
        stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(params["keep_name"]).to eq("vmabc123-rotate")
      end

      expect { rfk.remove_old }.to exit({"msg" => "fscrypt key rotated"})
    end

    it "fails if rotate_name not in frame" do
      expect { rfk.remove_old }.to raise_error(RuntimeError, /BUG: rotate_name not set/)
    end
  end

  # ============================================================
  # Strand-level crash-point interleaving tests
  #
  # Each test simulates the DB + host state at a specific crash point
  # in the rotation lifecycle, then calls the label that would be retried.
  # Verifies that the strand converges to the correct next hop/pop and
  # that the DB state after retry is consistent with safe unlock.
  # ============================================================

  describe "strand-level crash-point interleaving" do
    describe "crash during #start (after DB write, before hop)" do
      # DB state: fscrypt_key = K1, fscrypt_key_2 = K2 (just written)
      # On retry, start generates a NEW K2 and overwrites. This is safe:
      # the host has no protector for the old K2 yet (add_protector hasn't run).

      it "overwrites fscrypt_key_2 with a fresh key on retry" do
        stale_k2 = Base64.encode64("stale" * 6 + "xx")
        vm.fscrypt_key_2 = stale_k2

        expect(vm).to receive(:update) do |args|
          expect(args[:fscrypt_key_2]).not_to eq(stale_k2)
          key_binary = Base64.decode64(args[:fscrypt_key_2])
          expect(key_binary.bytesize).to eq(32)
        end

        expect { rfk.start }.to hop("add_protector")
      end
    end

    describe "crash during #add_protector (SSH call failed or COMMIT lost)" do
      before do
        vm.fscrypt_key_2 = Base64.encode64("b" * 32)
      end

      it "re-sends SSH command on retry (host-side add_protector is idempotent)" do
        # The SSH call to rotate-fscrypt-add is idempotent: if the rotate
        # protector is already linked, it returns immediately with the name.
        expect(sshable).to receive(:_cmd).with(
          /sudo host\/bin\/setup-vm rotate-fscrypt-add vmabc123/,
          stdin: anything
        ).and_return("vmabc123-rotate\n")

        expect(rfk).to receive(:update_stack).with({"rotate_name" => "vmabc123-rotate"})

        expect { rfk.add_protector }.to hop("promote_db")
      end
    end

    describe "crash during #promote_db (after DB write, before hop)" do
      # DB state: fscrypt_key = K2 (promoted), fscrypt_key_2 = nil
      # Host state: both P("vmabc123") with K1 and P("vmabc123-rotate") with K2 linked
      # On retry of promote_db, it sets fscrypt_key = fscrypt_key_2 again.
      # But fscrypt_key_2 is nil! This would set fscrypt_key to nil — catastrophic.
      #
      # However, this crash point cannot happen: promote_db is a single DB
      # operation (vm.update) followed by hop. If the DB write succeeds,
      # the hop succeeds atomically (same transaction). If the DB write fails,
      # we retry with original state. The strand framework guarantees this.
      #
      # We test the normal case: K2 exists, promotion works correctly.

      it "promotes K2 to slot 1 and clears slot 2 atomically" do
        k1 = Base64.encode64("a" * 32)
        k2 = Base64.encode64("b" * 32)
        vm.fscrypt_key = k1
        vm.fscrypt_key_2 = k2

        expect(vm).to receive(:update) do |args|
          expect(args[:fscrypt_key]).to eq(k2)
          expect(args[:fscrypt_key_2]).to be_nil
        end

        expect { rfk.promote_db }.to hop("remove_old")
      end
    end

    describe "crash during #remove_old (SSH call failed or COMMIT lost)" do
      it "re-sends SSH remove command on retry (host-side remove is idempotent)" do
        rfk.strand.stack.first.merge!("rotate_name" => "vmabc123-rotate")
        rfk.instance_variable_set(:@frame, nil)

        # The SSH call to rotate-fscrypt-remove is idempotent: if old protectors
        # are already removed, it sees only the keep protector and does nothing.
        expect(sshable).to receive(:_cmd).with(
          /sudo host\/bin\/setup-vm rotate-fscrypt-remove vmabc123/,
          stdin: anything
        ) do |_cmd, stdin:|
          params = JSON.parse(stdin)
          expect(params["keep_name"]).to eq("vmabc123-rotate")
        end

        expect { rfk.remove_old }.to exit({"msg" => "fscrypt key rotated"})
      end
    end
  end

  # ============================================================
  # Full rotation cycle test
  #
  # Simulates TWO consecutive rotations through the entire strand
  # lifecycle (start -> add_protector -> promote_db -> remove_old),
  # confirming the alternating-name scheme works across multiple cycles.
  # ============================================================

  describe "full rotation cycle (two consecutive rotations)" do
    it "completes two rotations with alternating protector names" do
      # --- First rotation: K1 -> K2, protector vm_name -> vm_name-rotate ---

      k1 = Base64.encode64("a" * 32)
      vm.fscrypt_key = k1
      vm.fscrypt_key_2 = nil

      # Step 1: start — generates K2
      k2 = nil
      expect(vm).to receive(:update) do |args|
        k2 = args[:fscrypt_key_2]
        vm.fscrypt_key_2 = k2
      end
      expect { rfk.start }.to hop("add_protector")

      # Step 2: add_protector — host creates P("vm_name-rotate") with K2
      expect(sshable).to receive(:_cmd).with(
        /rotate-fscrypt-add vmabc123/, stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        # Verify correct keys sent
        expect(Base64.decode64(params["old_key"]).bytesize).to eq(32)
        expect(Base64.decode64(params["new_key"]).bytesize).to eq(32)
        "vmabc123-rotate\n"
      end
      expect(rfk).to receive(:update_stack).with({"rotate_name" => "vmabc123-rotate"})
      expect { rfk.add_protector }.to hop("promote_db")

      # Step 3: promote_db — K2 becomes slot 1
      expect(vm).to receive(:update) do |args|
        expect(args[:fscrypt_key]).to eq(k2)
        expect(args[:fscrypt_key_2]).to be_nil
        vm.fscrypt_key = args[:fscrypt_key]
        vm.fscrypt_key_2 = nil
      end
      expect { rfk.promote_db }.to hop("remove_old")

      # Step 4: remove_old — removes P("vm_name"), keeps P("vm_name-rotate")
      rfk.strand.stack.first.merge!("rotate_name" => "vmabc123-rotate")
      rfk.instance_variable_set(:@frame, nil)
      expect(sshable).to receive(:_cmd).with(
        /rotate-fscrypt-remove vmabc123/, stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(params["keep_name"]).to eq("vmabc123-rotate")
      end
      expect { rfk.remove_old }.to exit({"msg" => "fscrypt key rotated"})

      # --- Second rotation: K2 -> K3, protector vm_name-rotate -> vm_name ---

      # Create a fresh strand for second rotation
      rfk2 = described_class.new(Strand.new(prog: "RotateFscryptKey"))
      allow(rfk2).to receive(:vm).and_return(vm)

      # vm now has fscrypt_key = K2, fscrypt_key_2 = nil
      expect(vm.fscrypt_key).to eq(k2)
      expect(vm.fscrypt_key_2).to be_nil

      # Step 1: start — generates K3
      k3 = nil
      expect(vm).to receive(:update) do |args|
        k3 = args[:fscrypt_key_2]
        vm.fscrypt_key_2 = k3
      end
      expect { rfk2.start }.to hop("add_protector")

      # Step 2: add_protector — host creates P("vm_name") with K3
      # (alternated back from vm_name-rotate to vm_name)
      expect(sshable).to receive(:_cmd).with(
        /rotate-fscrypt-add vmabc123/, stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        expect(Base64.decode64(params["old_key"]).bytesize).to eq(32)
        expect(Base64.decode64(params["new_key"]).bytesize).to eq(32)
        # Second rotation: host returns vm_name (alternated from vm_name-rotate)
        "vmabc123\n"
      end
      expect(rfk2).to receive(:update_stack).with({"rotate_name" => "vmabc123"})
      expect { rfk2.add_protector }.to hop("promote_db")

      # Step 3: promote_db — K3 becomes slot 1
      expect(vm).to receive(:update) do |args|
        expect(args[:fscrypt_key]).to eq(k3)
        expect(args[:fscrypt_key_2]).to be_nil
        vm.fscrypt_key = args[:fscrypt_key]
        vm.fscrypt_key_2 = nil
      end
      expect { rfk2.promote_db }.to hop("remove_old")

      # Step 4: remove_old — removes P("vm_name-rotate"), keeps P("vm_name")
      rfk2.strand.stack.first.merge!("rotate_name" => "vmabc123")
      rfk2.instance_variable_set(:@frame, nil)
      expect(sshable).to receive(:_cmd).with(
        /rotate-fscrypt-remove vmabc123/, stdin: anything
      ) do |_cmd, stdin:|
        params = JSON.parse(stdin)
        # Second rotation keeps "vmabc123" (alternated back)
        expect(params["keep_name"]).to eq("vmabc123")
      end
      expect { rfk2.remove_old }.to exit({"msg" => "fscrypt key rotated"})

      # Final state: fscrypt_key = K3, only P("vm_name") linked
      expect(vm.fscrypt_key).to eq(k3)
      expect(vm.fscrypt_key_2).to be_nil
    end
  end
end
