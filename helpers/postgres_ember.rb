# frozen_string_literal: true

# Used by the internal ember routes.
#
# These live here rather than beside one of those route files because route
# files are autoloaded per hash branch: a method defined in the project branch
# does not exist until somebody has hit a project URL.
class Clover
  # The ember id is the first label of the SNI name, the only way a client
  # names an ember to the gateway.
  def postgres_ember_from_hostname(host)
    label = host.split(".").first
    return nil if label.nil? || label.empty?
    id = UBID.to_uuid(label)
    return nil unless id && UBID.uuid_class_match?(id, PostgresEmber)
    PostgresEmber[id]&.ember
  end

  def postgres_ember_route_response(ember)
    {
      "ember_id" => ember.ubid,
      "state" => ember.state,
      "target_ip6" => ember.ip6&.to_s,
      "port" => 5432,
      # Absent by design: the hop is encrypted below PostgreSQL, so the
      # ember has no certificate of its own and the gateway connects in
      # plaintext. Setting upstream_tls here is what would switch it back.
      "upstream_tls" => false,
    }
  end

  # Which of the hosts a gateway still has cached no longer describe a running
  # ember.
  #
  # This piggybacks on the activity report because it is the only channel that
  # already runs in the right direction: a gateway's admin port, which would
  # take a pushed invalidation, is bound to localhost. Without it a gateway
  # keeps routing to an ember that has been paused until its own TTL runs
  # out, and a reconnect in that window pays a dial timeout first.
  def stale_routes(cached)
    return [] unless cached.is_a?(Array)

    by_id = cached.first(MAX_CACHED_ROUTES_REPORTED).to_h do |host|
      [UBID.to_uuid(host.to_s.split(".").first.to_s), host]
    end
    by_id.delete(nil)
    return [] if by_id.empty?

    running = Ember.where(id: by_id.keys, state: "running").select_map(:id)
    # Anything the gateway has that is not running here: paused, moving, or
    # gone entirely.
    by_id.except(*running).values
  end

  MAX_CACHED_ROUTES_REPORTED = 1000

  # Fold a batch of gateway reports into last_activity_at. Idle detection is
  # the only consumer, so the newest timestamp wins and anything older is
  # ignored rather than moving the clock backwards.
  def apply_activity_reports(reports)
    reports.each do |report|
      next unless report.is_a?(Hash)
      id = UBID.to_uuid(report["ember_id"].to_s)
      next unless id && UBID.uuid_class_match?(id, Ember)

      at = begin
        Time.parse(report["last_activity_at"].to_s)
      rescue ArgumentError, TypeError
        Time.now
      end
      Ember
        .where(id:)
        .where { last_activity_at < at }
        .update(last_activity_at: at)
    end
  end
end
