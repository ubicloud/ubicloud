# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::SshKeyRotation do
  subject(:ssh_test) {
    described_class.new(st)
  }

  let(:original_keypair) { SshKey.generate }
  let(:sshable) {
    Sshable.create(host: "test.localhost", raw_private_key_1: original_keypair.keypair)
  }

  let(:st) {
    Strand.create(prog: "Test::SshKeyRotation", label: "start", stack: [{"subject_id" => sshable.id}])
  }

  describe "#start" do
    it "buds RotateSshKey and hops to wait_rotation" do
      expect(ssh_test).to receive(:bud).with(Prog::RotateSshKey, {"subject_id" => sshable.id})
      expect { ssh_test.start }.to hop("wait_rotation")
    end
  end

  describe "#wait_rotation" do
    it "hops to verify_rotation when no children" do
      expect { ssh_test.wait_rotation }.to hop("verify_rotation")
    end

    it "naps if children exist" do
      Strand.create(parent_id: st.id, prog: "RotateSshKey", label: "start", stack: [{}], lease: Time.now + 10)
      expect { ssh_test.wait_rotation }.to nap(120)
    end
  end

  describe "#verify_rotation" do
    it "fails if raw_private_key_2 is not nil" do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
      expect(ssh_test.strand).to receive(:update).with(exitval: {msg: "Expected raw_private_key_2 to be nil after rotation"})
      expect { ssh_test.verify_rotation }.to hop("failed")
    end

    it "hops to verify_ssh_connection when slot 2 is nil" do
      expect { ssh_test.verify_rotation }.to hop("verify_ssh_connection")
    end
  end

  describe "#verify_ssh_connection" do
    it "verifies SSH connection works and hops to finish" do
      expect(ssh_test.sshable).to receive(:cmd).with("echo ssh-key-rotation-test verified").and_return("ssh-key-rotation-test verified\n")
      expect { ssh_test.verify_ssh_connection }.to hop("finish")
    end

    it "fails if SSH output is unexpected" do
      expect(ssh_test.sshable).to receive(:cmd).with("echo ssh-key-rotation-test verified").and_return("something else")
      expect(ssh_test.strand).to receive(:update).with(exitval: {msg: "Unexpected SSH output: something else"})
      expect { ssh_test.verify_ssh_connection }.to hop("failed")
    end
  end

  describe "#finish" do
    it "pops with success message" do
      expect { ssh_test.finish }.to exit({"msg" => "SSH key rotation verified successfully"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { ssh_test.failed }.to nap(15)
    end
  end
end
