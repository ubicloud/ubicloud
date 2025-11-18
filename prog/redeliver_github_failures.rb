# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  label def wait
    current_frame = strand.stack.first
    last_check_time = Time.parse(current_frame["last_check_at"])
    redeliver_failed_deliveries(last_check_time)
    current_frame["last_check_at"] = Time.now
    strand.modified!(:stack)
    strand.save_changes

    nap 2 * 60
  end

  def client
    @client ||= Github.app_client
  end

  def redeliver_failed_deliveries(*)
    failed = failed_deliveries(*).each do |delivery|
      Clog.emit("redelivering failed delivery") { {delivery: delivery.to_h} }
      client.post("/app/hook/deliveries/#{delivery[:id]}/attempts")
    end.count
    Clog.emit("redelivered failed deliveries") { {deliveries: {failed:}} }
  end

  def failed_deliveries(since, max_page = 50)
    all_deliveries = client.get("/app/hook/deliveries?per_page=100")
    page = 1
    while (next_url = client.last_response.rels[:next]&.href) && (since < all_deliveries.last[:delivered_at])
      if page >= max_page
        Clog.emit("failed deliveries page limit reached") { {deliveries: {max_page:, since:}} }
        break
      end
      page += 1
      all_deliveries += client.get(next_url)
    end

    Clog.emit("fetched deliveries") { {deliveries: {total: all_deliveries.count, page:, since:}} }

    all_deliveries
      .reject { it[:delivered_at] < since }
      .group_by { it[:guid] }
      .values
      .reject { |group| group.any? { it[:status] == "OK" } }
      .map { |group| group.max_by { it[:delivered_at] } }
  end
end
