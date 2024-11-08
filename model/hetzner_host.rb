# frozen_string_literal: true

require_relative "../model"

class HetznerHost < Sequel::Model
  one_to_one :vm_host, key: :id

  PROVIDER_NAME = "hetzner"

  def api
    @api ||= Hosting::HetznerApis.new(self)
  end

  def connection_string
    Config.hetzner_connection_string
  end

  def user
    Config.hetzner_user
  end

  def password
    Config.hetzner_password
  end
end

# Table: hetzner_host
# Columns:
#  id                | uuid | PRIMARY KEY
#  server_identifier | text | NOT NULL
# Indexes:
#  hetzner_host_pkey                  | PRIMARY KEY btree (id)
#  hetzner_host_server_identifier_key | UNIQUE btree (server_identifier)
# Foreign key constraints:
#  hetzner_host_id_fkey | (id) REFERENCES vm_host(id)
