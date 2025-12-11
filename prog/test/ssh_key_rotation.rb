# frozen_string_literal: true

class Prog::Test::SshKeyRotation < Prog::Test::Base
  subject_is :sshable

  label def start
    bud Prog::RotateSshKey, {"subject_id" => sshable.id}
    hop_wait_rotation
  end

  label def wait_rotation
    reap(:verify_rotation)
  end

  label def verify_rotation
    sshable.reload

    # Verify rotation completed: slot 2 should be nil (key was promoted to slot 1)
    fail_test "Expected raw_private_key_2 to be nil after rotation" if sshable.raw_private_key_2

    hop_verify_ssh_connection
  end

  label def verify_ssh_connection
    # Verify we can SSH with the new key
    ret = sshable.cmd("echo ssh-key-rotation-test verified")
    fail_test "Unexpected SSH output: #{ret}" unless ret.strip == "ssh-key-rotation-test verified"

    hop_finish
  end

  label def finish
    pop "SSH key rotation verified successfully"
  end

  label def failed
    nap 15
  end
end
