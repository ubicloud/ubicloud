# frozen_string_literal: true

require_relative "../model"

class VictoriaMetricsResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location, key: :location_id
  one_to_many :servers, class: :VictoriaMetricsServer, key: :victoria_metrics_resource_id
  many_to_one :private_subnet

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :reconfigure

  plugin :column_encryption do |enc|
    enc.column :admin_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
  end

  def hostname
    "#{name}.#{Config.victoria_metrics_host_name}"
  end

  def root_certs
    [root_cert_1, root_cert_2].join("\n") if root_cert_1 && root_cert_2
  end

  def set_firewall_rules
    vm_firewall_rules = []
    vm_firewall_rules.push({cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22..22)})
    vm_firewall_rules.push({cidr: "::/0", port_range: Sequel.pg_range(22..22)})
    vm_firewall_rules.push({cidr: "0.0.0.0/0", port_range: Sequel.pg_range(8427..8427)})
    vm_firewall_rules.push({cidr: "::/0", port_range: Sequel.pg_range(8427..8427)})
    private_subnet.firewalls.first.replace_firewall_rules(vm_firewall_rules)
  end

  def self.redacted_columns
    super + [:admin_password, :root_cert_1, :root_cert_2]
  end
end

# Table: victoria_metrics_resource
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
#  victoria_metrics_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  victoria_metrics_resource_location_id_fkey       | (location_id) REFERENCES location(id)
#  victoria_metrics_resource_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  victoria_metrics_resource_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  victoria_metrics_server | victoria_metrics_server_victoria_metrics_resource_id_fkey | (victoria_metrics_resource_id) REFERENCES victoria_metrics_resource(id)
