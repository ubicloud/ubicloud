# frozen_string_literal: true

class Serializers::Api::Postgres < Serializers::Base
  def self.base(pg)
    {
      id: pg.ubid,
      name: pg.name,
      state: pg.display_state,
      location: pg.location,
      vm_size: pg.target_vm_size,
      storage_size_gib: pg.target_storage_size_gib,
      ha_type: pg.ha_type
    }
  end

  structure(:default) do |pg|
    base(pg)
  end

  structure(:detailed) do |pg|
    base(pg).merge({
      connection_string: pg.connection_string,
      primary: pg.representative_server&.primary?,
      firewall_rules: pg.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Api::PostgresFirewallRule.serialize(fw) }
    }).merge((pg.timeline && pg.representative_server && pg.representative_server.primary?) ? {
      earliest_restore_time: pg.timeline.earliest_restore_time&.utc&.iso8601,
      latest_restore_time: pg.timeline.latest_restore_time&.utc&.iso8601
    } : {})
  end
end
