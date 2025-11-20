# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  label def wait
    last_check_time = Time.parse(frame["last_check_at"])
    nap 10 if Time.now - last_check_time < 2 * 60
    failures = failed_deliveries(last_check_time)
    failures.each_slice(50) do |deliveries|
      bud Prog::RedeliverGithubFailures, {"delivery_ids" => deliveries.map { it[:id] }}, "redeliver"
    end
    update_stack({"last_check_at" => Time.now.to_s})
    hop_wait_redelivers
  end

  label def wait_redelivers
    register_deadline("wait", 10 * 60)
    reap(:wait)
  end

  label def redeliver
    frame["delivery_ids"].each { client.post("/app/hook/deliveries/#{it}/attempts") }
    pop "redelivered failures"
  end

  def client
    @client ||= Github.app_client
  end

  def failed_deliveries(since, max_page = 100)
    all_deliveries = client.get("/app/hook/deliveries?per_page=100")
    page = 1
    while (next_url = client.last_response.rels[:next]&.href) && (since < all_deliveries.last[:delivered_at])
      break if page >= max_page
      page += 1
      all_deliveries += client.get(next_url)
    end
    failures = all_deliveries
      .reject { it[:delivered_at] < since }
      .group_by { it[:guid] }
      .values
      .reject { |group| group.any? { it[:status] == "OK" } }
      .map { |group| group.max_by { it[:delivered_at] } }
    Clog.emit("fetched github deliveries") { {fetched_github_deliveries: {total: all_deliveries.count, failed: failures.count, status: failures.map { it[:status] }.tally, page:, since:}} }
    failures
  end
end
