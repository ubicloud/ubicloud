# frozen_string_literal: true

class Prog::SshKeyRotator < Prog::Base
  subject_is :ssh_key_rotator

  ROTATE_USER = "rhizome_rotate"
  ROTATION_INTERVAL = 24 * 60 * 60  # 1 day
  NAP_DURATION = 12 * 60 * 60       # 12 hours
  FAR_FUTURE = 1000 * 365 * 24 * 60 * 60  # ~1000 years

  def self.assemble(sshable_id)
    DB.transaction do
      id = SshKeyRotator.generate_uuid
      SshKeyRotator.create_with_id(id, sshable_id: sshable_id)
      Strand.create_with_id(id, prog: "SshKeyRotator", label: "wait")
    end
  end

  def sshable
    @sshable ||= ssh_key_rotator.sshable
  end

  def before_run
    unless sshable
      pop "sshable no longer exists"
    end
  end

  def new_private_key
    SshKey.from_binary(sshable.raw_private_key_2).private_key
  end

  def compute_authorized_keys
    keys = sshable.keys.map(&:public_key).join("\n")
    # Managed VMs that have `ubi` do double duty for personnel access
    # (bad) need operator keys to be merged in too.
    if sshable.unix_user == "ubi" && Config.operator_ssh_public_keys
      keys += "\n#{Config.operator_ssh_public_keys}"
    end
    keys
  end

  label def wait
    # If no key is set yet, nap far into the future until woken
    nap FAR_FUTURE unless sshable.raw_private_key_1

    when_rotate_now_set? do
      decr_rotate_now
      hop_rotate_start
    end

    seconds = ssh_key_rotator.next_rotation_at - Time.now
    if seconds <= 0
      hop_rotate_start
    end

    nap(seconds + 1)
  end

  label def rotate_start
    sshable.update(raw_private_key_2: SshKey.generate.keypair)
    hop_rotate_prepare
  end

  label def rotate_prepare
    case sshable.d_check("ssh_key_rotate_prepare")
    when "Succeeded"
      sshable.d_clean("ssh_key_rotate_prepare")
      hop_rotate_test_new_user
    when "Failed", "NotStarted"
      # Runs as root - no sudo needed
      # Note: shellescape produces unquoted-safe output, so no quotes around placeholders
      script = NetSsh.command(<<BASH, rotate_user: ROTATE_USER)
set -ueo pipefail
if ! id :rotate_user 2>/dev/null; then
  adduser --disabled-password --gecos '' :rotate_user
fi
install -d -o :rotate_user -g :rotate_user -m 0700 /home/:rotate_user/.ssh
cat | install -m 0600 -o :rotate_user -g :rotate_user /dev/stdin /home/:rotate_user/.ssh/authorized_keys.new
sync /home/:rotate_user/.ssh/authorized_keys.new
mv /home/:rotate_user/.ssh/authorized_keys.new /home/:rotate_user/.ssh/authorized_keys
sync /home/:rotate_user/.ssh
BASH
      sshable.d_run("ssh_key_rotate_prepare", "bash", "-c", script, stdin: compute_authorized_keys)
    else
      raise "Unknown daemonizer state"
    end
    nap 5
  end

  label def rotate_test_new_user
    Net::SSH.start(sshable.host, ROTATE_USER,
      Sshable::COMMON_SSH_ARGS.merge(key_data: [new_private_key])) do |sess|
      ret = sess.exec!("echo test user login successful")
      fail "Unexpected exit status: #{ret.exitstatus}" unless ret.exitstatus.zero?
      fail "Unexpected output: #{ret}" unless ret == "test user login successful\n"
    end

    hop_rotate_promote
  end

  label def rotate_promote
    case sshable.d_check("ssh_key_rotate_promote")
    when "Succeeded"
      sshable.d_clean("ssh_key_rotate_promote")
      hop_rotate_test_target
    when "Failed", "NotStarted"
      # Runs as root - no sudo needed
      # Note: shellescape produces unquoted-safe output, so no quotes around placeholders
      script = NetSsh.command(<<BASH, rotate_user: ROTATE_USER, unix_user: sshable.unix_user)
set -ueo pipefail
install -m 0600 -o :unix_user -g :unix_user /home/:rotate_user/.ssh/authorized_keys /home/:unix_user/.ssh/authorized_keys.new
sync /home/:unix_user/.ssh/authorized_keys.new
mv /home/:unix_user/.ssh/authorized_keys.new /home/:unix_user/.ssh/authorized_keys
sync /home/:unix_user/.ssh
BASH
      sshable.d_run("ssh_key_rotate_promote", "bash", "-c", script)
    else
      raise "Unknown daemonizer state"
    end
    nap 5
  end

  label def rotate_test_target
    Net::SSH.start(sshable.host, sshable.unix_user,
      Sshable::COMMON_SSH_ARGS.merge(key_data: [new_private_key])) do |sess|
      ret = sess.exec!("echo target user login successful")
      fail "Unexpected exit status: #{ret.exitstatus}" unless ret.exitstatus.zero?
      fail "Unexpected output: #{ret}" unless ret == "target user login successful\n"
    end

    hop_rotate_finalize
  end

  label def rotate_finalize
    changed_records = sshable.this.exclude(raw_private_key_2: nil)
      .update(raw_private_key_1: Sequel[:raw_private_key_2], raw_private_key_2: nil)

    fail "Unexpected number of changed records: #{changed_records}" unless changed_records == 1

    ssh_key_rotator.update(next_rotation_at: Time.now + ROTATION_INTERVAL)

    hop_rotate_cleanup
  end

  label def rotate_cleanup
    # Check what processes are using the rotate user before attempting deletion
    sshable.cmd("sudo loginctl terminate-user :rotate_user", rotate_user: ROTATE_USER)

    procs = sshable.cmd("ps -u :rotate_user -o pid,comm,args 2>/dev/null || true", rotate_user: ROTATE_USER)
    unless procs.strip.empty?
      Clog.emit("Processes using rotate user") { {rotate_user_processes: {user: ROTATE_USER, output: procs}} }
    end

    sshable.cmd("sudo userdel -r :rotate_user", rotate_user: ROTATE_USER)
    hop_wait
  end
end
