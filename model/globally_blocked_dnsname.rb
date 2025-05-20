# frozen_string_literal: true

require_relative "../model"

class GloballyBlockedDnsname < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: globally_blocked_dnsname
# Columns:
#  id            | uuid                        | PRIMARY KEY
#  dns_name      | text                        | NOT NULL
#  ip_list       | inet[]                      |
#  last_check_at | timestamp without time zone |
# Indexes:
#  globally_blocked_dnsname_pkey         | PRIMARY KEY btree (id)
#  globally_blocked_dnsname_dns_name_key | UNIQUE btree (dns_name)
