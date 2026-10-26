# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  frame_reader :delivery_ids
  frame_accessor :last_check_at, :last_delivery_id

  label def wait
    last_check_time = Time.new(last_check_at)
    remaining_seconds = 2 * 60 - (Time.now - last_check_time)
    nap remaining_seconds.to_i + 1 if remaining_seconds > 0
    failures = failed_deliveries(last_delivery_id)
    # The GitHub client has a 5 second timeout, and Strand::LEASE_EXPIRATION is 120 seconds.
    # To stay within safe limits, we redeliver in batches of 25.
    failures.each_slice(25) do |deliveries|
      bud Prog::RedeliverGithubFailures, {"delivery_ids" => deliveries.map { it[:id] }}, "redeliver"
    end
    self.last_check_at = Time.now.to_s
    hop_wait_redelivers
  end

  label def wait_redelivers
    register_deadline("wait", 10 * 60)
    reap(:wait)
  end

  label def redeliver
    delivery_ids.each { client.post("/app/hook/deliveries/#{it}/attempts") }
    pop "redelivered failures"
  end

  def client
    @client ||= Github.app_client
  end

  def failed_deliveries(last_seen_id, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 80)
    all_deliveries = client.list_app_hook_deliveries(per_page: 100)
    newest_id = all_deliveries.first&.fetch(:id)
    boundary = last_seen_id && all_deliveries.index { it[:id] == last_seen_id }

    page = 1
    while boundary.nil? && last_seen_id && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline && (next_url = client.last_response.rels[:next]&.href)
      page += 1
      fetched = client.get(next_url)
      found = fetched.index { it[:id] == last_seen_id }
      boundary = all_deliveries.length + found if found
      all_deliveries += fetched
    end

    relevant = boundary ? all_deliveries.first(boundary) : all_deliveries
    self.last_delivery_id = newest_id if newest_id

    failures = relevant
      .group_by { it[:guid] }
      .values
      .reject { |group| group.any? { it[:status] == "OK" } }
      .map { |group| group.max_by { it[:delivered_at] } }
    Clog.emit("fetched github deliveries", {fetched_github_deliveries: {total: all_deliveries.count, failed: failures.count, status: failures.map { it[:status] }.tally, page:, last_seen_id:}})
    failures
  end
end
