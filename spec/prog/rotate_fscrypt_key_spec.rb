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
end
