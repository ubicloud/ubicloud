# frozen_string_literal: true

require_relative "../../model"

class DnsZone < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_many :dns_servers
  one_to_many :records, class: :DnsRecord
  one_to_one :active_billing_record, class: :BillingRecord, key: :resource_id do |ds| ds.active end

  include ResourceMethods
  include SemaphoreMethods

  semaphore :refresh_dns_servers

  def insert_record(record_name:, type:, ttl:, data:)
    record_name = add_dot_if_missing(record_name)
    DnsRecord.create_with_id(dns_zone_id: id, name: record_name, type: type, ttl: ttl, data: data)

    incr_refresh_dns_servers
  end

  def delete_record(record_name:, type: nil, data: nil)
    fail "Type needs to be specified if data is specified!" if data && type.nil?

    record_name = add_dot_if_missing(record_name)
    records = records_dataset.where(name: record_name, tombstoned: false)
    records = records.where(type: type) if type
    records = records.where(data: data) if data

    DB[:dns_record].import(
      [:id, :dns_zone_id, :name, :type, :ttl, :data, :tombstoned],
      records.select_map([:name, :type, :ttl, :data]).map do
        [DnsRecord.generate_uuid, id, *_1, true]
      end
    )

    incr_refresh_dns_servers
  end

  def purge_obsolete_records
    DB.transaction do
      # These are the records that are obsoleted by a another record with the
      # same fields but newer date. We can delete them even if they are not
      # seen yet.
      obsoleted_records = records_dataset
        .join(
          records_dataset
            .select_group(:dns_zone_id, :name, :type, :data)
            .select_append { max(created_at).as(:latest_created_at) }
            .as(:latest_dns_record),
          [:dns_zone_id, :name, :type, :data]
        )
        .where { dns_record[:created_at] < latest_dns_record[:latest_created_at] }.all

      # These are the tombstoned records, we can only delete them if they are
      # seen by all DNS servers. We join with seen_dns_records_by_dns_servers
      # and count the number of DNS servers to ensure that they are seen by all
      # DNS servers.
      dns_server_ids = dns_servers.map(&:id)
      seen_tombstoned_records = records_dataset
        .select_group(:id)
        .join(:seen_dns_records_by_dns_servers, dns_record_id: :id, dns_server_id: Sequel.any_uuid(dns_server_ids))
        .where(tombstoned: true)
        .having { count.function.* =~ dns_server_ids.count }.all

      records_to_purge = obsoleted_records + seen_tombstoned_records
      DB[:seen_dns_records_by_dns_servers].where(dns_record_id: Sequel.any_uuid(records_to_purge.map(&:id).uniq)).delete(force: true)
      records_to_purge.uniq(&:id).map(&:destroy)

      update(last_purged_at: Time.now)
    end
  end

  def add_dot_if_missing(record_name)
    (record_name[-1] == ".") ? record_name : record_name + "."
  end
end

# Table: dns_zone
# Columns:
#  id             | uuid                     | PRIMARY KEY
#  created_at     | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id     | uuid                     | NOT NULL
#  name           | text                     | NOT NULL
#  last_purged_at | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  dns_zone_pkey                 | PRIMARY KEY btree (id)
#  dns_zone_project_id_name_uidx | UNIQUE btree (project_id, name)
# Referenced By:
#  cert                  | cert_dns_zone_id_fkey                          | (dns_zone_id) REFERENCES dns_zone(id)
#  dns_record            | dns_record_dns_zone_id_fkey                    | (dns_zone_id) REFERENCES dns_zone(id)
#  dns_servers_dns_zones | dns_servers_dns_zones_dns_zone_id_fkey         | (dns_zone_id) REFERENCES dns_zone(id)
#  load_balancer         | load_balancer_custom_hostname_dns_zone_id_fkey | (custom_hostname_dns_zone_id) REFERENCES dns_zone(id)
