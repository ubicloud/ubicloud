# frozen_string_literal: true

require_relative "../model"

class ParseableResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location, read_only: true
  one_to_many :servers, class: :ParseableServer, is_used: true
  many_to_one :private_subnet, read_only: true

  plugin ResourceMethods, redacted_columns: [:root_cert_1, :root_cert_2],
    encrypted_columns: [:admin_password, :root_cert_key_1, :root_cert_key_2]
  plugin SemaphoreMethods, :destroy, :reconfigure

  def self.client_for_project(prj_id)
    if Config.parseable_endpoint_override
      return Parseable::Client.new(endpoint: Config.parseable_endpoint_override)
    end

    pr = nil
    [prj_id, Config.parseable_service_project_id].each do |project_id|
      next unless project_id
      break if (pr = ParseableResource.first(project_id:))
    end

    pr&.servers&.first&.client || (Parseable::Client.new(endpoint: "http://localhost:8000") if Config.development?)
  end

  def hostname
    "#{name}.#{Config.parseable_host_name}"
  end

  def root_certs
    [root_cert_1, root_cert_2].join("\n") if root_cert_1 && root_cert_2
  end

  def set_firewall_rules
    private_subnet.firewalls.first.replace_firewall_rules(
      Config.control_plane_outbound_cidrs.map { {cidr: it, port_range: Sequel.pg_range(22..22)} } + [
        {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(8000..8000)},
        {cidr: "::/0", port_range: Sequel.pg_range(8000..8000)}
      ]
    )
  end
end

# Table: parseable_resource
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  name                        | text                     | NOT NULL
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  admin_user                  | text                     | NOT NULL
#  admin_password              | text                     | NOT NULL
#  target_vm_size              | text                     | NOT NULL
#  target_storage_size_gib     | bigint                   | NOT NULL
#  root_cert_1                 | text                     |
#  root_cert_key_1             | text                     |
#  root_cert_2                 | text                     |
#  root_cert_key_2             | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id                  | uuid                     | NOT NULL
#  location_id                 | uuid                     | NOT NULL
#  private_subnet_id           | uuid                     |
# Indexes:
#  parseable_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  parseable_resource_location_id_fkey       | (location_id) REFERENCES location(id)
#  parseable_resource_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  parseable_resource_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  parseable_server | parseable_server_parseable_resource_id_fkey | (parseable_resource_id) REFERENCES parseable_resource(id)
