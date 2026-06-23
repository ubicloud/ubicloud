# frozen_string_literal: true

require_relative "../model"

class HostProvider < Sequel::Model
  many_to_one :vm_host, key: :id, is_used: true

  HETZNER_PROVIDER_NAME = "hetzner"
  LEASEWEB_PROVIDER_NAME = "leaseweb"
  AWS_PROVIDER_NAME = "aws"

  def api
    @api ||= Hosting::ProviderApis.for(self)
  end
end

# Table: host_provider
# Primary Key: (server_identifier, provider_name)
# Columns:
#  id                | uuid |
#  server_identifier | text |
#  provider_name     | text |
# Indexes:
#  host_provider_pkey | PRIMARY KEY btree (provider_name, server_identifier)
# Foreign key constraints:
#  host_provider_id_fkey | (id) REFERENCES vm_host(id)
