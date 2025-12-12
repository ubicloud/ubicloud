# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe SshKeyRotator do
  subject(:ssh_key_rotator) {
    described_class.create_with_id(described_class.generate_uuid, sshable_id: sshable.id)
  }

  let(:sshable) {
    Sshable.create_with_id(Sshable.generate_uuid, host: "test.example.com", raw_private_key_1: SshKey.generate.keypair)
  }

  describe "#sshable" do
    it "returns the associated sshable" do
      expect(ssh_key_rotator.sshable).to be_a(Sshable)
      expect(ssh_key_rotator.sshable.host).to eq("test.example.com")
    end
  end

  describe "#incr_rotate_now" do
    it "increments the rotate_now semaphore" do
      Strand.create_with_id(ssh_key_rotator.id, prog: "SshKeyRotator", label: "wait")
      expect { ssh_key_rotator.incr_rotate_now }.to change {
        Semaphore.where(strand_id: ssh_key_rotator.id, name: "rotate_now").count
      }.from(0).to(1)
    end
  end
end
