# frozen_string_literal: true

require_relative "../model"

class VictoriaMetricsResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location, key: :location_id
  one_to_many :servers, class: :VictoriaMetricsServer, key: :victoria_metrics_resource_id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :reconfigure

  plugin :column_encryption do |enc|
    enc.column :admin_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
  end

  def hostname
    "#{name}.#{Config.victoriametrics_host_name}"
  end

  def root_certs
    [root_cert_1, root_cert_2.to_s].join("\n") if root_cert_1 && root_cert_2
  end

  def self.redacted_columns
    super + [:admin_password, :root_cert_1, :root_cert_2]
  end
end

# Table: victoria_metrics_resource
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  name                        | text                     | NOT NULL
#  location                    | text                     | NOT NULL
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  admin_user                  | text                     | NOT NULL
#  admin_password              | text                     | NOT NULL
#  target_vm_size              | text                     | NOT NULL
#  root_cert_1                 | text                     |
#  root_cert_key_1             | text                     |
#  root_cert_2                 | text                     |
#  root_cert_key_2             | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id                  | uuid                     | NOT NULL
# Indexes:
#  victoria_metrics_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  victoria_metrics_resource_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  victoria_metrics_server | victoria_metrics_server_victoria_metrics_resource_id_fkey | (victoria_metrics_resource_id) REFERENCES victoria_metrics_resource(id)
