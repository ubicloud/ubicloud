# frozen_string_literal: true

class Prog::CheckForNewHostKeys < Prog::Base
  frame_accessor :last_sshable_id, :last_run_start

  WAIT_BETWEEN_SSHABLES = 10 * 60
  WAIT_BETWEEN_RUNS = 30 * 24 * 60 * 60

  label def start
    self.last_run_start = now
    self.last_sshable_id = "00000000-0000-0000-0000-000000000000"
    hop_check
  end

  label def check
    if (sshable = next_sshable)
      self.last_sshable_id = sshable.id

      begin
        sshable.check_for_new_host_keys
      rescue *Sshable::SSH_CONNECTION_ERRORS, Net::SSH::Exception => ex
        Clog.emit("unable to check for new host keys", Util.exception_to_hash(ex, into: {sshable_check_for_new_host_keys_failure: {ubid: sshable.ubid}}))
      end

      nap WAIT_BETWEEN_SSHABLES
    end

    hop_wait
  end

  label def wait
    remaining = last_run_start + WAIT_BETWEEN_RUNS - now
    hop_start if remaining < 0
    nap(remaining + 60)
  end

  private

  def next_sshable
    Sshable.by_id.with_host_keys.first(Sequel[:id] > last_sshable_id)
  end

  def now
    Time.now.to_i
  end
end
