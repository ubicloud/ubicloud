# frozen_string_literal: true

require "shellwords"

class Prog::RotateSshKey < Prog::Base
  subject_is :sshable

  def start
    sshable.update(raw_private_key_2: SshKey.generate.keypair)
    hop :install
  end

  def install
    public_keys = sshable.keys.map(&:public_key).join("\n")

    sshable.cmd(<<SH)
set -ueo pipefail
echo #{public_keys.shellescape} > ~/.ssh/authorized_keys2
SH
    hop :retire_old_key_on_server
  end

  def retire_old_key_on_server
    # Test authentication with new key new key at the same time.
    Net::SSH.start(sshable.host, "rhizome",
      Sshable::COMMON_SSH_ARGS.merge(key_data: [SshKey.from_binary(sshable.raw_private_key_2).private_key])) do |sess|
      sess.exec!(<<SH)
set -ueo pipefail
sync ~/.ssh/authorized_keys2
mv ~/.ssh/authorized_keys2 ~/.ssh/authorized_keys
sync ~/.ssh
SH
    end

    hop :retire_old_key_in_database
  end

  def retire_old_key_in_database
    changed_records = sshable.this.where(
      Sequel.~(raw_private_key_2: nil)
    ).update(raw_private_key_1: Sequel[:raw_private_key_2], raw_private_key_2: nil)

    fail unless changed_records == 1

    hop :test_rotation
  end

  def test_rotation
    # Bypass Sshable caching for the test, as it can have an existing
    # authorized session.
    Net::SSH.start(sshable.host, "rhizome",
      Sshable::COMMON_SSH_ARGS.merge(key_data: sshable.keys.map(&:private_key))) do |sess|
      ret = sess.exec!("echo key rotated successfully")
      fail unless ret.exitstatus.zero?
      fail unless ret == "key rotated successfully\n"
    end

    pop "key rotated successfully"
  end
end
