# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SshKeyRotator do
  subject(:skr) {
    described_class.new(Strand.new(id: ssh_key_rotator.id, prog: "SshKeyRotator", label: "wait"))
  }

  let(:sshable) {
    Sshable.create_with_id(Sshable.generate_uuid, host: "test.example.com", unix_user: "rhizome", raw_private_key_1: SshKey.generate.keypair)
  }

  let(:ssh_key_rotator) {
    SshKeyRotator.create_with_id(SshKeyRotator.generate_uuid, sshable_id: sshable.id)
  }

  before do
    allow(skr).to receive(:sshable).and_return(sshable)
  end

  describe ".assemble" do
    it "creates a ssh_key_rotator and strand" do
      new_sshable = Sshable.create_with_id(Sshable.generate_uuid, host: "new.example.com")
      st = described_class.assemble(new_sshable.id)
      expect(st).to be_a(Strand)
      expect(st.label).to eq("wait")
      expect(SshKeyRotator[st.id]).not_to be_nil
      expect(SshKeyRotator[st.id].sshable_id).to eq(new_sshable.id)
    end
  end

  describe "#before_run" do
    it "pops if sshable no longer exists" do
      expect(skr).to receive(:sshable).and_return(nil)
      expect { skr.before_run }.to exit({"msg" => "sshable no longer exists"})
    end

    it "does nothing if sshable exists" do
      expect { skr.before_run }.not_to raise_error
    end
  end

  describe "#wait" do
    it "naps far into future if no key set" do
      sshable.update(raw_private_key_1: nil)
      expect { skr.wait }.to nap(described_class::FAR_FUTURE)
    end

    it "hops to rotate_start if rotate_now semaphore set" do
      # Create a real strand and prog to cover semaphore block
      st = Strand.create_with_id(ssh_key_rotator.id, prog: "SshKeyRotator", label: "wait")
      ssh_key_rotator.incr_rotate_now
      real_skr = described_class.new(st)
      expect { real_skr.wait }.to hop("rotate_start")
    end

    it "hops to rotate_start if time to rotate" do
      ssh_key_rotator.update(next_rotation_at: Time.now - 1)
      expect { skr.wait }.to hop("rotate_start")
    end

    it "naps until rotation time plus one second" do
      now = Time.at(Time.now.to_i) # avoid database vs ruby precision differences
      expect(Time).to receive(:now).at_least(:once).and_return(now)
      ssh_key_rotator.update(next_rotation_at: now + 3600)
      expect { skr.wait }.to nap(3601)
    end
  end

  describe "#rotate_start" do
    it "generates new key and hops to rotate_prepare" do
      expect { skr.rotate_start }.to hop("rotate_prepare")
      expect(sshable.reload.raw_private_key_2).not_to be_nil
    end
  end

  describe "#rotate_prepare" do
    before do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
    end

    it "hops to rotate_test_new_user on success" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_prepare").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("ssh_key_rotate_prepare")
      expect { skr.rotate_prepare }.to hop("rotate_test_new_user")
    end

    it "starts daemonizer on NotStarted" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_prepare").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("ssh_key_rotate_prepare", "bash", "-c", anything, stdin: anything)
      expect { skr.rotate_prepare }.to nap(5)
    end

    it "retries on Failed" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_prepare").and_return("Failed")
      expect(sshable).to receive(:d_run).with("ssh_key_rotate_prepare", "bash", "-c", anything, stdin: anything)
      expect { skr.rotate_prepare }.to nap(5)
    end

    it "raises on unknown state" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_prepare").and_return("UnknownState")
      expect { skr.rotate_prepare }.to raise_error(RuntimeError, "Unknown daemonizer state")
    end
  end

  describe "#rotate_test_new_user" do
    let(:sess) { Net::SSH::Connection::Session.allocate }

    before do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
      expect(Net::SSH).to receive(:start).with(
        sshable.host,
        "rhizome_rotate",
        hash_including(:key_data)
      ).and_yield(sess)
    end

    it "hops to rotate_promote on success" do
      expect(sess).to receive(:_exec!).with("echo test user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("test user login successful\n", 0)
      )
      expect { skr.rotate_test_new_user }.to hop("rotate_promote")
    end

    it "fails if exit status not zero" do
      expect(sess).to receive(:_exec!).with("echo test user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("error", 1)
      )
      expect { skr.rotate_test_new_user }.to raise_error(RuntimeError, "Unexpected exit status: 1")
    end

    it "fails if output not expected" do
      expect(sess).to receive(:_exec!).with("echo test user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("wrong output", 0)
      )
      expect { skr.rotate_test_new_user }.to raise_error(RuntimeError, "Unexpected output: wrong output")
    end
  end

  describe "#rotate_promote" do
    before do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
    end

    it "hops to rotate_test_target on success" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_promote").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("ssh_key_rotate_promote")
      expect { skr.rotate_promote }.to hop("rotate_test_target")
    end

    it "starts daemonizer on NotStarted" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_promote").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("ssh_key_rotate_promote", "bash", "-c", anything)
      expect { skr.rotate_promote }.to nap(5)
    end

    it "retries on Failed" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_promote").and_return("Failed")
      expect(sshable).to receive(:d_run).with("ssh_key_rotate_promote", "bash", "-c", anything)
      expect { skr.rotate_promote }.to nap(5)
    end

    it "raises on unknown state" do
      expect(sshable).to receive(:d_check).with("ssh_key_rotate_promote").and_return("UnknownState")
      expect { skr.rotate_promote }.to raise_error(RuntimeError, "Unknown daemonizer state")
    end
  end

  describe "#rotate_test_target" do
    let(:sess) { Net::SSH::Connection::Session.allocate }

    before do
      sshable.update(raw_private_key_2: SshKey.generate.keypair)
      expect(Net::SSH).to receive(:start).with(
        sshable.host,
        sshable.unix_user,
        hash_including(:key_data)
      ).and_yield(sess)
    end

    it "hops to rotate_finalize on success" do
      expect(sess).to receive(:_exec!).with("echo target user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("target user login successful\n", 0)
      )
      expect { skr.rotate_test_target }.to hop("rotate_finalize")
    end

    it "fails if exit status not zero" do
      expect(sess).to receive(:_exec!).with("echo target user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("error", 1)
      )
      expect { skr.rotate_test_target }.to raise_error(RuntimeError, "Unexpected exit status: 1")
    end

    it "fails if output not expected" do
      expect(sess).to receive(:_exec!).with("echo target user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("wrong output", 0)
      )
      expect { skr.rotate_test_target }.to raise_error(RuntimeError, "Unexpected output: wrong output")
    end
  end

  describe "#rotate_finalize" do
    it "promotes pk2 to pk1 and updates next_rotation_at" do
      new_key = SshKey.generate.keypair
      sshable.update(raw_private_key_2: new_key)

      expect { skr.rotate_finalize }.to hop("rotate_cleanup")

      sshable.reload
      expect(sshable.raw_private_key_1).to eq(new_key)
      expect(sshable.raw_private_key_2).to be_nil

      ssh_key_rotator.reload
      expect(ssh_key_rotator.next_rotation_at).to be_within(60).of(Time.now + described_class::ROTATION_INTERVAL)
    end

    it "fails if no record changes" do
      # raw_private_key_2 is nil
      expect { skr.rotate_finalize }.to raise_error(RuntimeError, "Unexpected number of changed records: 0")
    end
  end

  describe "#rotate_cleanup" do
    it "deletes user and hops to wait" do
      expect(sshable).to receive(:_cmd).with("sudo loginctl terminate-user rhizome_rotate")
      expect(sshable).to receive(:_cmd).with("ps -u rhizome_rotate -o pid,comm,args 2>/dev/null || true").and_return("")
      expect(sshable).to receive(:_cmd).with("sudo userdel -r rhizome_rotate").and_return("")
      expect { skr.rotate_cleanup }.to hop("wait")
    end

    it "logs processes when they exist" do
      expect(sshable).to receive(:_cmd).with("sudo loginctl terminate-user rhizome_rotate")
      expect(sshable).to receive(:_cmd).with("ps -u rhizome_rotate -o pid,comm,args 2>/dev/null || true").and_return("PID COMMAND\n123 sshd")
      expect(sshable).to receive(:_cmd).with("sudo userdel -r rhizome_rotate").and_return("")
      expect { skr.rotate_cleanup }.to hop("wait")
    end
  end

  describe "#compute_authorized_keys" do
    it "returns only sshable keys for rhizome user" do
      result = skr.compute_authorized_keys
      expect(result).to eq(sshable.keys.first.public_key)
    end

    it "includes operator keys for ubi user" do
      sshable.update(unix_user: "ubi")
      expect(Config).to receive(:operator_ssh_public_keys).and_return("ssh-ed25519 BBB operator").twice
      result = skr.compute_authorized_keys
      expect(result).to eq("#{sshable.keys.first.public_key}\nssh-ed25519 BBB operator")
    end

    it "does not include operator keys for ubi user if not configured" do
      sshable.update(unix_user: "ubi")
      expect(Config).to receive(:operator_ssh_public_keys).and_return(nil)
      result = skr.compute_authorized_keys
      expect(result).to eq(sshable.keys.first.public_key)
    end
  end
end
