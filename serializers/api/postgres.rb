# frozen_string_literal: true

class Serializers::Api::Postgres < Serializers::Base
  def self.serialize_internal(pg, options = {})
    base = {
      id: pg.ubid,
      name: pg.name,
      state: pg.display_state,
      location: pg.display_location,
      vm_size: pg.target_vm_size,
      storage_size_gib: pg.target_storage_size_gib,
      ha_type: pg.ha_type
    }

    if options[:detailed]
      base.merge!(
        connection_string: pg.connection_string,
        primary: pg.representative_server&.primary?,
        firewall_rules: pg.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Common::PostgresFirewallRule.serialize(fw) }
      )

      if pg.timeline && pg.representative_server&.primary?
        base[:earliest_restore_time] = pg.timeline.earliest_restore_time&.utc&.iso8601
        base[:latest_restore_time] = pg.timeline.latest_restore_time&.utc&.iso8601
      end
    end

    base
  end
end
