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

  def redeliver_failed_deliveries(since, max_page: 50)
    latest_by_guid = {}
    last_page = failed_deliveries(latest_by_guid, "/app/hook/deliveries?per_page=100", since, max_page)
    Clog.emit("fetched deliveries") { {deliveries: {total: latest_by_guid.count, page: max_page - last_page, since:}} }
    failed = latest_by_guid.values.reject { it == true }.each do |delivery|
      Clog.emit("redelivering failed delivery") { {delivery: delivery.to_h} }
      client.post("/app/hook/deliveries/#{delivery[:id]}/attempts")
    end.count
    Clog.emit("redelivered failed deliveries") { {deliveries: {failed:}} }
  end

  def failed_deliveries(latest_by_guid, url, since, remaining_pages)
    if remaining_pages <= 0
      Clog.emit("failed deliveries page limit reached") { {deliveries: {since:}} }
      return 0
    end

    deliveries = client.get(url)
    deliveries.each do |delivery|
      next if delivery[:delivered_at] < since
      guid = delivery[:guid]
      latest_by_guid[guid] = true if delivery[:status] == "OK"
      next if latest_by_guid[guid] == true
      entry = latest_by_guid[guid]
      if entry.nil? || delivery[:delivered_at] > entry[:delivered_at]
        latest_by_guid[guid] = delivery
      end
    end

    if (next_url = client.last_response.rels[:next]&.href) && (since < deliveries.last[:delivered_at])
      failed_deliveries(latest_by_guid, next_url, since, remaining_pages - 1)
    end
    remaining_pages
  end
end
