# frozen_string_literal: true

class Serializers::Postgres < Serializers::Base
  def self.serialize_internal(pg, options = {})
    base = {
      id: pg.ubid,
      name: pg.name,
      state: pg.display_state,
      location: pg.display_location,
      vm_size: pg.vm_size,
      target_vm_size: pg.target_vm_size,
      storage_size_gib: pg.storage_size_gib,
      target_storage_size_gib: pg.target_storage_size_gib,
      version: pg.version,
      ha_type: pg.ha_type,
      flavor: pg.flavor,
      ca_certificates: pg.ca_certificates,
      maintenance_window_start_at: pg.maintenance_window_start_at,
      read_replica: !!pg.read_replica?,
      parent: pg.parent&.path,
      tags: pg.tags || []
    }

    if options[:detailed]
      base.merge!(
        connection_string: pg.connection_string,
        primary: pg.representative_server&.primary?,
        firewall_rules: Serializers::PostgresFirewallRule.serialize(pg.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }),
        metric_destinations: pg.metric_destinations.map { {id: it.ubid, username: it.username, url: it.url} },
        read_replicas: Serializers::Postgres.serialize(pg.read_replicas, {include_path: true})
      )

      if pg.timeline && pg.representative_server&.primary?
        begin
          base[:earliest_restore_time] = pg.timeline.earliest_restore_time&.utc&.iso8601
        rescue => ex
          Clog.emit("Failed to get earliest restore time") { Util.exception_to_hash(ex) }
        end
        base[:latest_restore_time] = pg.timeline.latest_restore_time&.utc&.iso8601
      end
    end

    base
  end
end
