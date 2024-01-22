# frozen_string_literal: true

class Serializers::Web::Postgres < Serializers::Base
  def self.base(pg)
    {
      id: pg.id,
      ubid: pg.ubid,
      path: pg.path,
      name: pg.name,
      state: pg.display_state,
      location: pg.location,
      vm_size: pg.target_vm_size,
      storage_size_gib: pg.target_storage_size_gib
    }
  end

  structure(:default) do |pg|
    base(pg)
  end

  structure(:detailed) do |pg|
    base(pg).merge({
      connection_string: pg.connection_string,
      primary?: pg.server&.primary?,
      firewall_rules: pg.firewall_rules.sort_by { |fwr| fwr.cidr.version && fwr.cidr.to_s }.map { |fw| Serializers::Web::PostgresFirewallRule.serialize(fw) }
    }).merge((pg.timeline && pg.server && pg.server.primary?) ? {
      earliest_restore_time: pg.timeline.earliest_restore_time&.utc&.iso8601,
      latest_restore_time: pg.timeline.latest_restore_time&.utc&.iso8601
    } : {})
  end
end
