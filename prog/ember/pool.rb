# frozen_string_literal: true

# Keeps a location's warm pool of blank embers topped up.
#
# A blank is a full restore against a fresh volume, held ready so that a
# create becomes a password change rather than a boot. The pool is owned by
# the location rather than by each host: what a tenant waits on is a blank
# somewhere nearby, and holding the target per host would move it every time
# a host is added or drained, which is exactly when the pool matters most.
class Prog::Ember::Pool < Prog::Base
  subject_is :ember_pool

  POLL_SECONDS = 30
  REAP_MARGIN_SECONDS = 60

  def self.assemble(location_id, workload:, target: nil)
    fail "no such location" unless Location[location_id]
    if (existing = EmberPool[location_id:, workload:])
      return existing
    end

    DB.transaction do
      pool = EmberPool.create(
        location_id:, workload:,
        target: target || Config.ember_pool_target,
      )
      Strand.create_with_id(pool, prog: "Ember::Pool", label: "start")
      pool
    end
  end

  label def start
    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    decr_refill
    hop_refill
  end

  label def refill
    hosts.each { reconcile_blanks(it) }
    retire_aged_blanks

    nap POLL_SECONDS unless ember_pool.enabled
    nap POLL_SECONDS if ember_pool.target - ember_pool.blanks_held <= 0

    host = host_for_blank
    nap POLL_SECONDS if host.nil?

    template = newest_template(host)
    nap POLL_SECONDS if template.nil?

    # One at a time: each blank is a restore, and the point of the pool is to
    # absorb bursts, not to create them.
    add_blank(host, template)
    nap POLL_SECONDS
  end

  # The ember host in this location with room and the fewest blanks already
  # waiting, so the pool spreads rather than piling onto whichever host
  # answered first.
  def host_for_blank
    hosts.select { it.ember.free_slots.positive? }.min_by { it.ember.blank_slots }
  end

  def hosts
    ember_pool.hosts_dataset.all
  end

  # The blank's volume belongs to the service project until an ember claims it,
  # at which point that row becomes the ember's own. It is created here, rather
  # than invented by the host, because claiming a blank keeps the volume: one
  # named by the host would leave a tenant's data somewhere the control plane
  # could not name or move.
  def add_blank(host, template)
    workload_class = Ember.workload_class(template.workload)
    volume = Prog::Storage::DetachableVolumeNexus.assemble(
      project_id: Config.ember_service_project_id, location_id: ember_pool.location_id,
      size_gib: workload_class.default_volume_size_gib, source_image: template.data_image,
    )

    begin
      host.ember.cmd_json("sudo host/bin/ember create-blank", stdin: {
        "template_id" => template.ubid,
        "workload" => template.workload,
        "guest" => workload_class.blank_guest_config,
        "cpu_percent_limit" => workload_class.default_cpu_percent_limit,
        "volume" => blank_volume_payload(template, volume),
      })
      volume.record_host(host:, caught_up: true)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
      Clog.emit("ember blank creation failed", {host: host.ubid, error: e.message})
      # The blank never came up, so its volume row describes nothing.
      DB.transaction do
        Strand.where(id: volume.id).destroy
        volume.destroy
      end
    end
  end

  # Volume rows for blanks a host no longer holds. A host that restarts, or
  # loses a blank, leaves rows behind that nothing will ever claim, so the
  # host is asked what its slots hold and the rows it does not know are
  # destroyed. Only rows more than a minute old are judged, so a blank being
  # made right now is not taken for a lost one.
  def reconcile_blanks(host)
    held = host.ember.cmd_json("sudo host/bin/ember list").fetch("slots").filter_map { it["volume_id"] }
    host.ember.blank_volumes_dataset
      .where(Sequel[:created_at] < Time.now - REAP_MARGIN_SECONDS)
      .exclude(id: held.map { UBID.to_uuid(it) })
      .all
      .each(&:incr_destroy)
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
    Clog.emit("reconciling blanks failed", {host: host.ubid, error: e.message})
  end

  # A blank restored from a template that has since been retired is worse than
  # no blank at all, so they are aged out rather than kept indefinitely. A
  # blank is named by its volume on the host.
  def retire_aged_blanks
    cutoff = Time.now - Config.ember_blank_max_age_seconds
    hosts.each do |host|
      host.ember.blank_volumes_dataset.where(Sequel[:created_at] < cutoff).all.each do |volume|
        host.ember.cmd_json("sudo host/bin/ember destroy :blank", blank: volume.ubid)
        volume.incr_destroy
      rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
        Clog.emit("retiring an aged blank failed", {host: host.ubid, error: e.message})
      end
    end
  end

  def newest_template(host)
    EmberTemplate
      .where(id: EmberTemplateHost.where(vm_host_id: host.id, state: "ready")
        .select(:ember_template_id))
      .where(state: "ready", cpu_signature: host.cpu_signature)
      .order(Sequel.desc(:created_at))
      .first
  end

  # It reads through to the template's seed image until written, so "empty"
  # already means an initialised cluster; without the image name there is
  # nothing to read through to.
  def blank_volume_payload(template, volume)
    {
      "id" => volume.ubid,
      "size_gib" => volume.size_gib,
      "source" => {"type" => "new", "image" => template.data_image},
    }.merge(volume.key_material)
  end

  label def destroy
    decr_destroy
    ember_pool.destroy
    pop "ember pool destroyed"
  end
end
