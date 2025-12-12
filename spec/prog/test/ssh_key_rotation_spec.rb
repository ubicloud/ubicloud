# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::SshKeyRotation do
  subject(:test_prog) {
    described_class.new(strand)
  }

  let(:original_key) { SshKey.generate.keypair }

  let(:sshable) {
    s = create_mock_sshable(raw_private_key_1: original_key)
    allow(s).to receive(:ssh_key_rotator).and_return(ssh_key_rotator)
    allow(s).to receive(:reload).and_return(s)
    s
  }

  let(:rotator_strand) {
    instance_double(Strand, label: "wait", reload: nil)
  }

  let(:ssh_key_rotator) {
    r = instance_double(SshKeyRotator, strand: rotator_strand, incr_rotate_now: nil, id: "test-rotator-id", next_rotation_at: Time.now + 24 * 60 * 60)
    allow(r).to receive(:reload).and_return(r)
    r
  }

  let(:strand) {
    Strand.new(prog: "Test::SshKeyRotation", label: "start", stack: [{}])
  }

  before do
    allow(test_prog).to receive(:sshable).and_return(sshable)
  end

  describe "#start" do
    it "fails if no ssh_key_rotator exists" do
      allow(sshable).to receive(:ssh_key_rotator).and_return(nil)
      expect { test_prog.start }.to hop("failed")
      expect(strand.exitval).to eq({"msg" => "No ssh_key_rotator found for sshable"})
    end

    it "captures key hash, triggers rotation, and hops to wait_rotation" do
      original_key_hash = Digest::SHA256.hexdigest(original_key)
      expect(ssh_key_rotator).to receive(:incr_rotate_now)
      expect { test_prog.start }.to hop("wait_rotation")
      expect(strand.stack.first["original_key_hash"]).to eq(original_key_hash)
    end
  end

  describe "#wait_rotation" do
    # Override strand to include original_key_hash in the stack
    let(:strand) {
      Strand.new(
        prog: "Test::SshKeyRotation",
        label: "wait_rotation",
        stack: [{"original_key_hash" => Digest::SHA256.hexdigest(original_key)}]
      )
    }

    it "hops to verify_ssh when key has changed and rotator is in wait state" do
      new_key = SshKey.generate.keypair
      allow(sshable).to receive(:raw_private_key_1).and_return(new_key)
      allow(rotator_strand).to receive(:label).and_return("wait")
      expect { test_prog.wait_rotation }.to hop("verify_ssh")
    end

    it "naps if key has not changed yet" do
      # Key unchanged, still waiting for rotation
      allow(rotator_strand).to receive(:label).and_return("rotate_cleanup")
      expect { test_prog.wait_rotation }.to nap(5)
    end

    it "naps if key changed but rotator not yet in wait state" do
      new_key = SshKey.generate.keypair
      allow(sshable).to receive(:raw_private_key_1).and_return(new_key)
      allow(rotator_strand).to receive(:label).and_return("rotate_cleanup")
      expect { test_prog.wait_rotation }.to nap(5)
    end
  end

  describe "#verify_ssh" do
    it "hops to verify_cleanup on successful SSH" do
      allow(sshable).to receive(:_cmd).with("echo rotation_test_success").and_return("rotation_test_success\n")
      expect { test_prog.verify_ssh }.to hop("verify_cleanup")
    end

    it "fails on unexpected SSH output" do
      allow(sshable).to receive(:_cmd).with("echo rotation_test_success").and_return("unexpected output")
      expect { test_prog.verify_ssh }.to hop("failed")
      expect(strand.exitval["msg"]).to include("Unexpected SSH output")
    end

    it "fails on SSH error" do
      allow(sshable).to receive(:_cmd).with("echo rotation_test_success").and_raise(Sshable::SshError.new("cmd", "", "connection refused", 1, nil))
      expect { test_prog.verify_ssh }.to hop("failed")
      expect(strand.exitval["msg"]).to include("SSH with new key failed")
    end
  end

  describe "#verify_cleanup" do
    before do
      allow(rotator_strand).to receive(:label).and_return("wait")
      allow(ssh_key_rotator).to receive(:next_rotation_at).and_return(Time.now + 24 * 60 * 60)
    end

    it "naps if rotator not yet in wait state" do
      allow(rotator_strand).to receive(:label).and_return("rotate_cleanup")
      expect { test_prog.verify_cleanup }.to nap(5)
    end

    it "naps if next rotation is too soon" do
      allow(ssh_key_rotator).to receive(:next_rotation_at).and_return(Time.now + 1 * 60 * 60)
      expect { test_prog.verify_cleanup }.to nap(5)
    end

    it "hops to finish when test user does not exist" do
      allow(sshable).to receive(:_cmd).with("id rhizome_rotate 2>&1 || echo 'user_not_found'").and_return("user_not_found\n")
      expect { test_prog.verify_cleanup }.to hop("finish")
    end

    it "hops to finish when id command returns no such user" do
      allow(sshable).to receive(:_cmd).with("id rhizome_rotate 2>&1 || echo 'user_not_found'").and_return("id: 'rhizome_rotate': no such user\n")
      expect { test_prog.verify_cleanup }.to hop("finish")
    end

    it "hops to finish when SSH error occurs (user not found)" do
      allow(sshable).to receive(:_cmd).with("id rhizome_rotate 2>&1 || echo 'user_not_found'").and_raise(Sshable::SshError.new("cmd", "", "", 1, nil))
      expect { test_prog.verify_cleanup }.to hop("finish")
    end

    it "fails if test user still exists" do
      allow(sshable).to receive(:_cmd).with("id rhizome_rotate 2>&1 || echo 'user_not_found'").and_return("uid=1001(rhizome_rotate) gid=1001(rhizome_rotate)")
      expect { test_prog.verify_cleanup }.to hop("failed")
      expect(strand.exitval["msg"]).to include("Test user rhizome_rotate still exists")
    end
  end

  describe "#finish" do
    it "pops with success message" do
      expect { test_prog.finish }.to exit({"msg" => "SSH key rotation verified successfully"})
    end
  end

  describe "#failed" do
    it "pops with failure message" do
      expect { test_prog.failed }.to exit({"msg" => "SSH key rotation test failed"})
    end
  end
end
