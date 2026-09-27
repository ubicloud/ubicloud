# frozen_string_literal: true

# The synchronous create, resume and pause paths (design doc 7.2).
#
# These run inside the API request rather than on a strand, because the whole
# point of an ember is that it appears in well under a second and a strand
# scan alone costs up to a second.
#
# The structure is dictated by a measurement. Wrapping the host call in the
# same transaction as the state change holds a pooled database connection for
# the call's whole duration, and with the default web pool of four connections
# a 500 ms cold create caps the process at about eight creates per second with
# a p99 over ten seconds, while the median stays clean and hides it. So each
# operation commits its state change first, calls the host with no connection
# held, and reopens a short transaction to record the result. The generation
# column and the reconciling nexus cover the window in between.
module EmberOperations
  module_function

  class NoCapacity < StandardError; end

  # How many hosts to try before giving up on a create.
  PLACEMENT_ATTEMPTS = 3

  # How long a host call on the create path may take. These run inside an API
  # request, which must not sit on a host that has hung.
  HOST_TIMEOUT = 15

  # Pausing is not on the connection path, and it has to stop the guest,
  # detach the volume and shut a VM down. Timing it out at the create path's
  # budget leaves the host having done the work and the control plane
  # believing it did not.
  PAUSE_TIMEOUT = 90

  # Bring a brand new ember up, preferring a warm blank.
  #
  # The workload row is created inside the same transaction by the block, so
  # that an ember never exists for a moment with nothing to run. Returns the
  # ember, running, or raises NoCapacity.
  def create(project_id:, location:, workload:, version:, name: nil,
    expires_at: nil, &make_workload_row)
    template = newest_ready_template(location:, workload:, version:)
    raise NoCapacity, "no ready #{workload} #{version} template in #{location.name}" unless template
    workload_class = Ember.workload_class(workload)

    ember = DB.transaction do
      # The design says the name defaults to the ubid, but a name that is
      # exactly ubid-shaped is rejected so that name and id stay unambiguous
      # in URLs. Derive something readable from it instead.
      ubid = Ember.generate_ubid
      Prog::Storage::DetachableVolumeNexus.assemble(
        project_id:, location_id: location.id, owner_id: ubid.to_uuid,
        size_gib: workload_class.default_volume_size_gib, source_image: template.data_image,
      )
      created = Ember.create_with_id(
        ubid.to_uuid,
        project_id:, location_id: location.id,
        name: name || "ember-#{ubid.to_s[2, 10]}",
        state: "creating", ember_template_id: template.id,
        memory_mib: template.memory_mib,
        cpu_percent_limit: workload_class.default_cpu_percent_limit,
        idle_timeout_seconds: workload_class.default_idle_timeout_seconds,
        expires_at:,
      )
      yield(created)
      Strand.create_with_id(created, prog: "Ember::Nexus", label: "wait")
      created
    end

    start_on_a_host(ember, template, may_claim_blank: true)
    ember
  end

  # Bring a paused ember back. Safe to call concurrently: whoever loses the
  # race sees the ember already running.
  def resume(ember)
    return ember if ember.reload.running?

    template = ember.ember_template
    mark(ember, "resuming")
    start_on_a_host(ember, template)
    ember
  end

  # Stop an ember, keeping its volume.
  def pause(ember)
    return ember unless ember.reload.running?

    host = ember.vm_host
    generation = mark(ember, "pausing")

    result = begin
      host.ember.cmd_json("sudo host/bin/ember pause :ember", ember: ember.ubid,
        stdin: {"generation" => generation}, timeout: PAUSE_TIMEOUT)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
      # The host may have paused it anyway; the nexus reconciles.
      Clog.emit("ember pause failed", {ember: ember.ubid, error: e.message})
      ember.incr_checkup
      raise
    end

    DB.transaction do
      ember.update(state: "paused", vm_host_id: nil, slot: nil, ip6: nil,
        state_changed_at: Time.now, last_paused_at: Time.now)
      ember.detachable_volume.record_host(host:, caught_up: result["caught_up"])
    end
    ember
  end

  # Try each candidate host in turn. A host-level failure is not the request's
  # failure: the next host may well work.
  def start_on_a_host(ember, template, may_claim_blank: false)
    volume = ember.detachable_volume
    # A volume already laid out on a host would come up empty anywhere else,
    # so only the hosts it can start on are candidates.
    candidates = VmHost.ember_candidates_for(template).select { volume.stripe_source_for(it) }
    errors = []
    errors << "#{volume.vm_host.ubid}, which holds its volume, cannot take it" if candidates.empty? && volume.vm_host

    candidates.first(PLACEMENT_ATTEMPTS).each do |host|
      result = try_host(ember, host, errors, may_claim_blank:)
      next unless result

      DB.transaction do
        adopt_claimed_volume(ember, result["volume_id"])
        ember.update(state: "running", vm_host_id: host.id,
          slot: result["slot"], ip6: result["ip6"], state_changed_at: Time.now,
          last_started_at: Time.now, last_activity_at: Time.now)
        ember.detachable_volume.record_host(host:, caught_up: result["caught_up"])
      end
      Clog.emit("ember started", {ember: ember.ubid, host: host.ubid,
                                    phases: result["phases_ms"]})
      return ember
    end

    ember.incr_checkup
    raise NoCapacity, "could not place #{ember.ubid}: #{errors.join("; ")}"
  end

  # Claiming a blank hands the ember the blank's volume instead of the one
  # it was created with. Both are the control plane's, so this is a swap of
  # one row for another rather than a loss of track: the volume that was never
  # attached to anything goes away.
  def adopt_claimed_volume(ember, volume_ubid)
    # Anything that is not one of our ubids is a volume this control plane
    # never created -- a blank left over from an older version of host/bin/ember,
    # say -- and adopting it is not possible.
    id = volume_ubid && UBID.to_uuid(volume_ubid.to_s)
    return if id.nil?
    claimed = DetachableVolume[id]
    unused = ember.detachable_volume
    return if claimed.nil? || claimed.id == unused.id

    Strand.where(id: unused.id).destroy
    unused.destroy
    claimed.update(project_id: ember.project_id)
    claimed.assign_owner(ember)
    ember.associations.delete(:detachable_volume)
  end

  def try_host(ember, host, errors, may_claim_blank: false)
    volume = ember.detachable_volume
    payload = {
      "ember_id" => ember.ubid,
      "generation" => ember.generation,
      "template_id" => ember.ember_template.ubid,
      "cpu_percent_limit" => ember.cpu_percent_limit,
      "volume" => {
        "id" => volume.ubid,
        "size_gib" => volume.size_gib,
        "source" => volume.stripe_source_for(host),
      }.merge(volume.key_material),
      "workload" => ember.workload,
      "guest" => ember.guest_config,
    }

    # Only an ember that has never held data may take a blank: claiming one
    # keeps the blank's volume, so a resume that claimed would hand the tenant
    # somebody else's empty database instead of their own data.
    if may_claim_blank && host.ember.blank_slots.positive?
      begin
        return host.ember.cmd_json("sudo host/bin/ember claim-blank", stdin: payload, timeout: HOST_TIMEOUT)
      rescue Sshable::SshError => e
        # Another create took the last blank since it was counted. Restoring
        # is the same ember, just slower.
        raise unless ember_command_error(e) == "slot_exhausted"
      end
    end
    host.ember.cmd_json("sudo host/bin/ember create", stdin: payload, timeout: HOST_TIMEOUT)
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
    # A failed call is not necessarily a failed operation: the host may well
    # have done the work, and the ember nexus reconciles.
    errors << "#{host.ubid}: #{failure_detail(e)}"
    nil
  end

  # What host/bin/ember prints, as JSON, for a failure it expects.
  def ember_command_report(error)
    JSON.parse(error.stdout)
  rescue JSON::ParserError, TypeError
    {}
  end

  def ember_command_error(error) = ember_command_report(error)["error"]

  # Why a host call failed, as far as the host said.
  def failure_detail(error)
    return error.message unless error.is_a?(Sshable::SshError)
    ember_command_report(error)["detail"] || error.stderr.to_s.strip.lines.last&.strip || error.message
  end

  # Commit the state change before calling the host, and bump the generation so
  # the host can reject a call issued against an older view.
  def mark(ember, state)
    DB.transaction do
      ember.update(state:, generation: ember.generation + 1, state_changed_at: Time.now)
    end
    ember.generation
  end

  def newest_ready_template(location:, workload:, version:)
    EmberTemplate
      .where(location_id: location.id, workload:, version:, state: "ready")
      .order(Sequel.desc(:created_at))
      .first
  end
end
