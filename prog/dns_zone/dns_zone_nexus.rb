# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::DnsZone::DnsZoneNexus < Prog::Base
  subject_is :dns_zone

  label def wait
    if dns_zone.last_purged_at < Time.now - 60 * 60 * 1 # ~1 hour
      register_deadline("wait", 5 * 60)
      hop_purge_obsolete_records
    end

    when_refresh_dns_servers_set? do
      register_deadline("wait", 5 * 60)
      hop_refresh_dns_servers
    end

    nap 10
  end

  label def refresh_dns_servers
    decr_refresh_dns_servers

    dns_zone.dns_servers.each do |dns_server|
      records_to_rectify = dns_zone.records_dataset
        .left_join(:seen_dns_records_by_dns_servers, dns_record_id: :id, dns_server_id: dns_server.id)
        .where(Sequel[:seen_dns_records_by_dns_servers][:dns_record_id] => nil)
        .order(Sequel.asc(:created_at)).all

      next if records_to_rectify.empty?

      commands = ["zone-abort #{dns_zone.name}", "zone-begin #{dns_zone.name}"]
      records_to_rectify.each do |r|
        commands << if r.tombstoned
          "zone-unset #{dns_zone.name} #{r.name} #{r.ttl} #{r.type} #{r.data}"
        else
          "zone-set #{dns_zone.name} #{r.name} #{r.ttl} #{r.type} #{r.data}"
        end
      end
      commands << "zone-commit #{dns_zone.name}"

      dns_server.run_commands_on_all_vms(commands)

      DB[:seen_dns_records_by_dns_servers].multi_insert(records_to_rectify.map { {dns_record_id: it.id, dns_server_id: dns_server.id} })
    end

    hop_wait
  end

  label def purge_obsolete_records
    dns_zone.purge_obsolete_records
    hop_wait
  end
end
