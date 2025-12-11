# frozen_string_literal: true

class Prog::RotateSshKey < Prog::Base
  subject_is :sshable

  ROTATE_USER = "rhizome_rotate"

  def compute_authorized_keys(operator_keys: Config.operator_ssh_public_keys)
    # Operator keys first (if not rhizome user) so we notice splicing issues
    [(operator_keys if sshable.unix_user != "rhizome"), *sshable.keys.map(&:public_key)].compact.join("\n")
  end

  def new_private_key
    SshKey.from_binary(sshable.raw_private_key_2).private_key
  end

  label def start
    sshable.update(raw_private_key_2: SshKey.generate.keypair)
    hop_create_test_user
  end

  label def create_test_user
    begin
      sshable.cmd("sudo adduser --disabled-password --gecos '' :test_user", test_user: ROTATE_USER)
    rescue Sshable::SshError => e
      raise unless /The user `.*' already exists\./.match?(e.stdout + e.stderr)
    end
    sshable.cmd("sudo install -d -o :test_user -g :test_user -m 0700 /home/:test_user/.ssh", test_user: ROTATE_USER)
    hop_install_keys_to_test_user
  end

  label def install_keys_to_test_user
    # Write to .new then mv to guarantee same-filesystem atomic rename
    sshable.cmd(<<BASH, test_user: ROTATE_USER, authorized_keys: compute_authorized_keys)
set -ueo pipefail
echo :authorized_keys | sudo install -m 0600 -o :test_user -g :test_user /dev/stdin /home/:test_user/.ssh/authorized_keys.new
sudo sync /home/:test_user/.ssh/authorized_keys.new
sudo mv /home/:test_user/.ssh/authorized_keys.new /home/:test_user/.ssh/authorized_keys
sudo sync /home/:test_user/.ssh
BASH
    hop_test_login_to_test_user
  end

  label def test_login_to_test_user
    # Test SSH login to test user with the NEW key (slot 2)
    Net::SSH.start(sshable.host, ROTATE_USER,
      Sshable::COMMON_SSH_ARGS.merge(key_data: [new_private_key])) do |sess|
      ret = sess.exec!("echo test user login successful")
      fail "Unexpected exit status: #{ret.exitstatus}" unless ret.exitstatus.zero?
      fail "Unexpected output: #{ret}" unless ret == "test user login successful\n"
    end

    hop_promote_keys_to_target_user
  end

  label def promote_keys_to_target_user
    # install copies with mode/owner set atomically, mv is atomic rename (same-fs guaranteed)
    sshable.cmd(<<BASH, test_user: ROTATE_USER, target_user: sshable.unix_user)
set -ueo pipefail
sudo install -m 0600 -o :target_user -g :target_user /home/:test_user/.ssh/authorized_keys /home/:target_user/.ssh/authorized_keys.new
sudo sync /home/:target_user/.ssh/authorized_keys.new
sudo mv /home/:target_user/.ssh/authorized_keys.new /home/:target_user/.ssh/authorized_keys
sudo sync /home/:target_user/.ssh
BASH
    hop_verify_target_user_login
  end

  label def verify_target_user_login
    # Verify we can login as target user with new key BEFORE deleting test user
    Net::SSH.start(sshable.host, sshable.unix_user,
      Sshable::COMMON_SSH_ARGS.merge(key_data: [new_private_key])) do |sess|
      ret = sess.exec!("echo target user login successful")
      fail "Unexpected exit status: #{ret.exitstatus}" unless ret.exitstatus.zero?
      fail "Unexpected output: #{ret}" unless ret == "target user login successful\n"
    end

    hop_retire_old_key_in_database
  end

  label def retire_old_key_in_database
    changed_records = sshable.this.where(
      Sequel.~(raw_private_key_2: nil)
    ).update(raw_private_key_1: Sequel[:raw_private_key_2], raw_private_key_2: nil)

    fail "Unexpected number of changed records: #{changed_records}" unless changed_records == 1

    hop_delete_test_user
  end

  label def delete_test_user
    begin
      sshable.cmd("sudo userdel -r :test_user", test_user: ROTATE_USER)
    rescue Sshable::SshError => e
      raise unless /user .* does not exist|does not exist in the passwd file/.match?(e.stdout + e.stderr)
    end
    pop "key rotated successfully"
  end
end
