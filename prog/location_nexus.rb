# frozen_string_literal: true

class Prog::LocationNexus < Prog::Base
  subject_is :location

  LEAD_SECONDS = 48 * 60 * 60     # provision the replacement standby this far ahead
  BYPASS_SECONDS = 24 * 60 * 60   # inside this, skip the customer window and fail over now

  def self.assemble(**)
    DB.transaction do
      location = Location.create(**)
      Strand.create_with_id(location, prog: "LocationNexus", label: "wait")
    end
  end

  label def wait
    now = Time.now
    location.scheduled_maintenance_events.each do |vm_id, not_before|
      next if not_before - now > LEAD_SECONDS
      next unless (server = PostgresServer.first(vm_id:))

      unless server.recycle_set?
        server.incr_recycle
        Clog.emit("scheduled postgres failover for cloud maintenance", {ubid: server.ubid, provider: location.provider, vm_id:, not_before:})
      end

      if not_before - now <= BYPASS_SECONDS && !server.resource.bypass_maintenance_window_set?
        server.resource.incr_bypass_maintenance_window
      end
    end
    nap 3600
  end

  label def destroy
    decr_destroy
    location.destroy
    pop "location destroyed"
  end
end
