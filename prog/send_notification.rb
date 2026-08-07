# frozen_string_literal: true

# Sends a customer notification, away from the code that decides to notify, so
# that slow delivery never delays that code. Raising here makes respirate retry
# with backoff. The frame carries the event and its details; how to deliver
# each event is decided here, at delivery time.
class Prog::SendNotification < Prog::Base
  frame_reader :event, :resource_id, :params

  # Respirate's exponential backoff spreads these attempts over several minutes.
  MAX_ATTEMPTS = 10

  def self.assemble(event:, resource_id:, **params)
    Strand.create(prog: "SendNotification", label: "start", stack: [{event:, resource_id:, params:}])
  end

  label def start
    send_notification
    pop "sent"
  rescue => ex
    raise if strand.try < MAX_ATTEMPTS
    Clog.emit("notification failed", Util.exception_to_hash(ex, into: {event:, resource_id:}))
    pop "gave up after #{MAX_ATTEMPTS} attempts"
  end

  def send_notification
    deliver = :"deliver_#{event}"
    fail "unknown notification event: #{event}" unless respond_to?(deliver)
    send(deliver)
  end

  # The resource may be destroyed between the event and this delivery, in
  # which case there is nobody left to notify.
  def deliver_postgres_failover
    PostgresResource[resource_id]&.send_failover_email(**params.transform_keys(&:to_sym))
  end
end
