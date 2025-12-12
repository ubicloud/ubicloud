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

    update_stack({
      "original_key_hash" => Digest::SHA256.hexdigest(sshable.raw_private_key_1)
    })

    ssh_key_rotator.incr_rotate_now

    hop_wait_rotation
  end

  label def wait_rotation
    current_key_hash = Digest::SHA256.hexdigest(sshable.raw_private_key_1)

    # Simply wait for key to change - rotation is in progress
    if current_key_hash != frame["original_key_hash"]
      hop_verify_ssh
    end

    # Still waiting for rotation to complete
    nap 5
  end

  label def verify_ssh
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
    # Verify the test user was cleaned up
    begin
      result = sshable.cmd("id rhizome_rotate 2>&1 || echo 'user_not_found'")
      unless result.include?("user_not_found") || result.include?("no such user")
        fail_test "Test user rhizome_rotate still exists"
      end
    rescue Sshable::SshError
      # Expected - user should not exist
    end

    hop_finish
  end

  label def finish
    pop "SSH key rotation verified successfully"
  end

  label def failed
    pop "SSH key rotation test failed"
  end
end
