# frozen_string_literal: true

# Shared by the project-scoped and internal ember routes.
#
# These live here rather than beside one of those route files because route
# files are autoloaded per hash branch: a method defined in the project branch
# does not exist until somebody has hit a project URL.
class Clover
  # The options the create form offers: what the project can actually use, so
  # a location it cannot see is not on the list.
  def postgres_ember_create_options
    @locations = Location.for_project(@project.id).all
    @pg_versions = EmberTemplate.where(state: "ready", workload: "postgres").distinct.select_map(:version).sort
  end

  def postgres_ember_create
    location = postgres_ember_location

    unless @project.quota_available?("PostgresEmberCount", 1)
      fail Validation::ValidationFailed.new("size" => "Quota exceeded: the project already has as many embers as it is allowed")
    end

    name = typecast_params.nonempty_str("name")
    Validation.validate_name(name) if name

    ember = postgres_ember_create_with_capacity(
      location:, name:,
      pg_version: typecast_params.nonempty_str("pg_version") || "18",
      database: typecast_params.nonempty_str("database") || "postgres",
    )
    audit_log(ember, "create")
    if api?
      response.status = 201
      Serializers::PostgresEmber.serialize(ember, include_credentials: true)
    else
      flash["notice"] = "Ember created"
      request.redirect ember
    end
  end

  # An ember is addressed without a location in its URL, so the location is a
  # create-time parameter. Anything the project cannot see is not a location as
  # far as it is concerned.
  def postgres_ember_location
    requested = typecast_params.nonempty_str("location")
    dataset = Location.for_project(@project.id)
    location = requested ? dataset[display_name: requested] : dataset[name: "hetzner-fsn1"]
    unless location
      fail Validation::ValidationFailed.new("location" => "is not a valid location")
    end
    location
  end

  def postgres_ember_create_with_capacity(**)
    PostgresEmberOperations.create(project_id: @project.id, **)
  rescue EmberOperations::NoCapacity => e
    Clog.emit("ember create refused", {project: @project.ubid, error: e.message})
    fail CloverError.new(503, "NoCapacity", "No capacity for an ember right now, please try again")
  end

  # Audit logging is the caller's job: an anonymous caller has no account to
  # attribute the action to.
  def postgres_ember_action(ember, action)
    case action
    when "pause"
      # Asynchronous: pausing is not something the caller waits on, and the
      # nexus already knows how to do it.
      ember.incr_pause
    when "resume"
      begin
        EmberOperations.resume(ember.ember)
      rescue EmberOperations::NoCapacity
        fail CloverError.new(503, "NoCapacity", "No capacity to resume this ember right now")
      end
    when "reset-password"
      postgres_ember_reset_password(ember)
    end
    Serializers::PostgresEmber.serialize(ember.reload, include_credentials: true)
  end

  def postgres_ember_reset_password(ember)
    password = SecureRandom.urlsafe_base64(24)
    ember.update(superuser_password: password)
    return unless ember.running? && ember.vm_host

    ember.vm_host.ember.cmd_json("sudo host/bin/ember configure :ember", ember: ember.ubid,
      stdin: {"generation" => ember.generation, "workload" => ember.ember.workload, "guest" => {"superuser_password" => password}},
      timeout: EmberOperations::HOST_TIMEOUT)
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
    # The stored password is now ahead of the guest's. The nexus reconciles.
    Clog.emit("ember password reset failed", {ember: ember.ubid, error: e.message})
    ember.incr_checkup
    fail CloverError.new(503, "TemporaryFailure", "Could not reach the ember to change its password")
  end

  # Move an anonymous ember into this project. The token is single use: its
  # digest is cleared, so a leaked claim URL cannot be replayed. The password
  # is kept, so the connection string an application was already given keeps
  # working; anyone who had it keeps access until the password is reset.
  def postgres_ember_claim(token)
    ember = PostgresEmber
      .where(id: Ember.where(project_id: Config.ember_service_project_id).select(:id))
      .exclude(claim_token_digest: nil)
      .all
      .find { it.claim_token_matches?(token) }
    unless ember
      fail CloverError.new(404, "ResourceNotFound", "No unclaimed ember for that token")
    end
    if ember.expired?
      fail CloverError.new(410, "Gone", "That ember has expired")
    end
    unless @project.quota_available?("PostgresEmberCount", 1)
      fail Validation::ValidationFailed.new("size" => "Quota exceeded: the project already has as many embers as it is allowed")
    end

    DB.transaction do
      ember.ember.update(project_id: @project.id, expires_at: nil)
      ember.update(claimed_at: Time.now, claim_token_digest: nil)
      ember.detachable_volume.update(project_id: @project.id)
    end
    audit_log(ember, "claim")
    return ember.reload unless api?
    Serializers::PostgresEmber.serialize(ember.reload, include_credentials: true)
  end

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
