# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  optional_input :last_check_at, Time.now.to_s

  label def wait
    Github.redeliver_failed_deliveries(Time.parse(last_check_at))

    strand.stack.first.merge!({"last_check_at" => Time.now})
    strand.modified!(:stack)
    strand.save_changes

    nap 5 * 60
  end
end
