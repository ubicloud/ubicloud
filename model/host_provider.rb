# frozen_string_literal: true

require_relative "../model"

class HostProvider < Sequel::Model
  many_to_one :vm_host, key: :id

  HETZNER_PROVIDER_NAME = "hetzner"
  LEASEWEB_PROVIDER_NAME = "leaseweb"

  PROVIDER_METHODS = %w[connection_string user password].freeze

  PROVIDER_METHODS.each do |method_name|
    define_method(method_name) do
      Config.send(:"#{provider_name}_#{method_name}")
    end
  end

  def api
    @api ||= Object.const_get("Hosting::#{provider_name.capitalize}Apis").new(self)
  end
end

# Table: host_provider
# Columns:
#  id                | uuid |
#  server_identifier | text | NOT NULL
#  provider_name     | text | NOT NULL
# Indexes:
#  host_provider_provider_name_server_identifier_index | UNIQUE btree (provider_name, server_identifier)
#  host_provider_server_identifier_key                 | UNIQUE btree (server_identifier)
# Foreign key constraints:
#  host_provider_id_fkey | (id) REFERENCES vm_host(id)
