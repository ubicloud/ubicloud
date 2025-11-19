# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  label def wait
    last_check_time = Time.parse(frame["last_check_at"])
    Github.redeliver_failed_deliveries(last_check_time)
    update_stack({"last_check_at" => Time.now})

    nap 2 * 60
  end
end
