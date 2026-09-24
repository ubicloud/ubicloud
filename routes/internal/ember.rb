# frozen_string_literal: true

# The private API the ember gateways use (design doc 7.4).
#
# Three calls, all on the connection path, so all of them are shaped to be
# cheap: a route lookup the gateway caches, a resume it holds a client for,
# and a batched activity report.
class Clover
  hash_branch(:internal_prefix, "ember") do |r|
    r.get "route" do
      host = typecast_params.nonempty_str!("host")
      ember = postgres_ember_from_hostname(host)
      next 404 unless ember

      postgres_ember_route_response(ember)
    end

    r.on :ubid_uuid do |id|
      # This is the Postgres gateway's API, so the only embers it can see are
      # Postgres ones -- the same restriction the route lookup applies.
      ember = PostgresEmber[id]&.ember
      next 404 unless ember

      r.post "resume" do
        begin
          EmberOperations.resume(ember)
        rescue EmberOperations::NoCapacity => e
          # Not an error the gateway can do anything about; it tells the client
          # to retry, which is what 57P03 means to libpq.
          Clog.emit("ember resume refused", {ember: ember.ubid, error: e.message})
          next 503
        rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
          Clog.emit("ember resume failed", {ember: ember.ubid, error: e.message})
          ember.incr_checkup
          next 503
        end

        postgres_ember_route_response(ember.reload)
      end
    end
  end
end
