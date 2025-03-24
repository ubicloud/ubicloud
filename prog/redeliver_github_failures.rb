# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  label def wait
    current_frame = strand.stack.first
    last_check_time = Time.parse(current_frame["last_check_at"])
    Github.redeliver_failed_deliveries(last_check_time)
    current_frame["last_check_at"] = Time.now
    strand.modified!(:stack)
    strand.save_changes

    nap 2 * 60
  end
end
