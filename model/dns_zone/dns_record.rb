# frozen_string_literal: true

require_relative "../../model"

class DnsRecord < Sequel::Model
  plugin ResourceMethods
end

# Table: dns_record
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  dns_zone_id | uuid                     |
#  name        | text                     | NOT NULL
#  type        | text                     | NOT NULL
#  ttl         | bigint                   | NOT NULL
#  data        | text                     | NOT NULL
#  tombstoned  | boolean                  | NOT NULL DEFAULT false
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  dns_record_pkey                             | PRIMARY KEY btree (id)
#  dns_record_dns_zone_id_name_type_data_index | btree (dns_zone_id, name, type, data)
# Foreign key constraints:
#  dns_record_dns_zone_id_fkey | (dns_zone_id) REFERENCES dns_zone(id)
# Referenced By:
#  seen_dns_records_by_dns_servers | seen_dns_records_by_dns_servers_dns_record_id_fkey | (dns_record_id) REFERENCES dns_record(id)
