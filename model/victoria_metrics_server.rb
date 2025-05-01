# frozen_string_literal: true

require_relative "../model"

class VictoriaMetricsServer < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm
  many_to_one :resource, class: :VictoriaMetricsResource, key: :victoria_metrics_resource_id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :initial_provisioning, :restart, :reconfigure

  plugin :column_encryption do |enc|
    enc.column :cert_key
  end

  def public_ipv6_address
    vm.ip6.to_s
  end

  def self.redacted_columns
    super + [:cert]
  end
end

# Table: victoria_metrics_server
# Columns:
#  id                           | uuid                     | PRIMARY KEY
#  created_at                   | timestamp with time zone | NOT NULL DEFAULT now()
#  cert                         | text                     |
#  cert_key                     | text                     |
#  certificate_last_checked_at  | timestamp with time zone | NOT NULL DEFAULT now()
#  victoria_metrics_resource_id | uuid                     | NOT NULL
#  vm_id                        | uuid                     | NOT NULL
# Indexes:
#  victoria_metrics_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  victoria_metrics_server_victoria_metrics_resource_id_fkey | (victoria_metrics_resource_id) REFERENCES victoria_metrics_resource(id)
#  victoria_metrics_server_vm_id_fkey                        | (vm_id) REFERENCES vm(id)
