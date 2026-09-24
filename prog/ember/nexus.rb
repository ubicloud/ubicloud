# frozen_string_literal: true

# Everything about an ember that is not on the sub-second path.
#
# Create, resume and pause run synchronously inside the API request
# (EmberOperations); this prog owns what can afford to wait: noticing that a
# ember has gone idle, expiring one nobody claimed, reconciling an ember
# whose host call failed halfway, and tearing it down.
class Prog::Ember::Nexus < Prog::Base
  subject_is :ember

  # How long to wait between sweeps of a healthy ember. Short, so an ember
  # pauses close to its idle timeout; each sweep is one database read.
  WAIT_SECONDS = 5

  # States the synchronous path owns while it is in the middle of something.
  TRANSITIONAL_STATES = %w[creating resuming pausing].freeze

  # Longer than any of those operations can reasonably take, including the
  # host call's own timeouts.
  TRANSITION_GRACE_SECONDS = 300

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    when_checkup_set? do
      decr_checkup
      hop_reconcile
    end

    when_pause_set? do
      decr_pause
      hop_pause
    end

    # Nothing is decided about an ember that the synchronous path is still
    # working on: a create that is placing it, a resume that is bringing it
    # back. Destroying one mid-create leaves the placement writing to a row
    # that is no longer there, and pausing one mid-resume fights it.
    #
    # Not forever, though. A create that crashed leaves the row transitional
    # with nobody coming back for it, and only the host can say what actually
    # happened to it.
    if TRANSITIONAL_STATES.include?(ember.state)
      hop_reconcile if Time.now - ember.state_changed_at > TRANSITION_GRACE_SECONDS
      nap WAIT_SECONDS
    end

    if ember.expired? && !ember.protected
      Clog.emit("ember expired", {ember: ember.ubid})
      ember.incr_destroy
      nap 0
    end

    if ember.idle?
      hop_pause
    end

    nap WAIT_SECONDS
  end

  label def pause
    unless ember.running?
      hop_wait
    end

    begin
      EmberOperations.pause(ember)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
      Clog.emit("ember pause failed", {ember: ember.ubid, error: e.message})
      hop_reconcile
    end
    hop_wait
  end

  # Ask the host what actually happened, rather than guessing, after a
  # synchronous call failed or timed out. The host is the authority on whether
  # a VM exists; the control plane's row is only a record of intent.
  label def reconcile
    host = ember.vm_host
    if host.nil?
      # No host claims it, so nothing is running it, whatever the row says.
      # This covers a create that crashed before placement as well as a
      # ember that believes it is up: paused is the truth in both cases, and
      # the next connection resumes it.
      unless ember.paused?
        ember.update(state: "paused", slot: nil, ip6: nil,
          state_changed_at: Time.now)
      end
      hop_wait
    end

    begin
      observed = host.ember.cmd_json("sudo host/bin/ember describe :ember", ember: ember.ubid)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
      Clog.emit("ember reconcile failed", {ember: ember.ubid, error: e.message})
      nap 30
    end

    case observed["state"]
    when "running"
      ember.update(state: "running", slot: observed["slot"], ip6: observed["ip6"],
        state_changed_at: Time.now)
    when nil, "absent"
      ember.update(state: "paused", vm_host_id: nil, slot: nil, ip6: nil,
        state_changed_at: Time.now)
    else
      # Mid-flight on the host; look again shortly rather than fighting it.
      nap 5
    end
    hop_wait
  end

  label def destroy
    decr_destroy

    if (host = ember.vm_host)
      begin
        host.ember.cmd_json("sudo host/bin/ember destroy :ember", ember: ember.ubid,
          stdin: {"generation" => ember.generation, "delete_volume" => false})
      rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
        # Keep trying: leaving a VM behind leaks a slot.
        Clog.emit("ember destroy failed", {ember: ember.ubid, error: e.message})
        nap 15
      end
    end

    volume = ember.detachable_volume
    DB.transaction do
      ember.destroy
      volume.incr_destroy
    end
    pop "ember destroyed"
  end
end
