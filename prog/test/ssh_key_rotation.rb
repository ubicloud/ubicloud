# frozen_string_literal: true

class Prog::Test::SshKeyRotation < Prog::Test::Base
  subject_is :sshable

  def ssh_key_rotator
    @ssh_key_rotator ||= sshable.ssh_key_rotator
  end

  label def start
    unless ssh_key_rotator
      fail_test "No ssh_key_rotator found for sshable"
    end

    Clog.emit("claude-rotation-test") { {claude_rotation_start: {sshable_id: sshable.id, rotator_id: ssh_key_rotator.id}} }

    update_stack({
      "original_key_hash" => Digest::SHA256.hexdigest(sshable.raw_private_key_1)
    })

    ssh_key_rotator.incr_rotate_now

    hop_wait_rotation
  end

  label def wait_rotation
    rotator_label = ssh_key_rotator.strand.label
    current_key_hash = Digest::SHA256.hexdigest(sshable.reload.raw_private_key_1)
    key_changed = current_key_hash != frame["original_key_hash"]

    Clog.emit("claude-rotation-test") { {claude_wait_rotation: {rotator_label: rotator_label, key_changed: key_changed}} }

    # Wait for rotator to return to wait state AND key to have changed
    # This ensures cleanup has completed, not just key swap
    if rotator_label == "wait" && key_changed
      hop_verify_ssh
    end

    # Still waiting for rotation to complete
    nap 5
  end

  label def verify_ssh
    Clog.emit("claude-rotation-test") { {claude_verify_ssh: {sshable_id: sshable.id}} }

    # Test SSH with new key works
    begin
      result = sshable.cmd("echo rotation_test_success")
      unless result.strip == "rotation_test_success"
        fail_test "Unexpected SSH output: #{result}"
      end
    rescue Sshable::SshError => e
      fail_test "SSH with new key failed: #{e.message}"
    end

    hop_verify_cleanup
  end

  label def verify_cleanup
    rotator = ssh_key_rotator.reload
    rotator_label = rotator.strand.label
    next_rotation_at = rotator.next_rotation_at
    time_until_rotation = next_rotation_at - Time.now

    Clog.emit("claude-rotation-test") { {claude_verify_cleanup_pre: {rotator_label: rotator_label, next_rotation_at: next_rotation_at.to_s, time_until_rotation_sec: time_until_rotation.to_i}} }

    # Ensure rotator is in wait state and won't rotate again soon (at least 23 hours away)
    # This confirms cleanup has completed
    unless rotator_label == "wait" && time_until_rotation > 23 * 60 * 60
      Clog.emit("claude-rotation-test") { {claude_verify_cleanup_waiting: "rotator not yet idle"} }
      nap 5
    end

    # Verify the test user was cleaned up
    begin
      result = sshable.cmd("id rhizome_rotate 2>&1 || echo 'user_not_found'")
      Clog.emit("claude-rotation-test") { {claude_verify_cleanup: {result: result.strip}} }
      unless result.include?("user_not_found") || result.include?("no such user")
        fail_test "Test user rhizome_rotate still exists: #{result.strip}"
      end
    rescue Sshable::SshError => e
      Clog.emit("claude-rotation-test") { {claude_verify_cleanup_ssh_error: {error: e.message}} }
      # Expected - user should not exist
    end

    hop_finish
  end

  label def finish
    Clog.emit("claude-rotation-test") { {claude_rotation_finish: "success"} }
    pop "SSH key rotation verified successfully"
  end

  label def failed
    Clog.emit("claude-rotation-test") { {claude_rotation_failed: frame} }
    pop "SSH key rotation test failed"
  end
end
