# frozen_string_literal: true

require_relative "../model"

# A paused VM's memory snapshot that embers are restored from.
#
# Templates are immutable and keyed by everything that has to match for a
# restore to work: location, architecture, CPU signature, the workload and its version, and
# the images and hypervisor version baked into them. A new image produces a new
# template; the old one is retired once no host needs it.
class EmberTemplate < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :location
  one_to_many :ember_template_hosts, read_only: true
  one_to_many :embers, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :retire

  def ready?
    state == "ready"
  end

  # Hosts that have finished building this template.
  def ready_hosts
    ember_template_hosts.select { it.state == "ready" }.map(&:vm_host)
  end
end

# Table: ember_template
# Columns:
#  id            | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(410)
#  created_at    | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  location_id   | uuid                     | NOT NULL
#  arch          | text                     | NOT NULL
#  cpu_signature | text                     | NOT NULL
#  workload      | text                     | NOT NULL
#  version       | text                     | NOT NULL
#  root_image    | text                     | NOT NULL
#  data_image    | text                     | NOT NULL
#  ch_version    | text                     | NOT NULL
#  memory_mib    | integer                  | NOT NULL DEFAULT 384
#  vcpus         | integer                  | NOT NULL DEFAULT 1
#  state         | text                     | NOT NULL DEFAULT 'building'::text
# Indexes:
#  ember_template_pkey          | PRIMARY KEY btree (id)
#  ember_template_placement_idx | btree (location_id, workload, version, cpu_signature, state)
# Check constraints:
#  ember_template_arch_check  | (arch = ANY (ARRAY['x64'::text, 'arm64'::text]))
#  ember_template_state_check | (state = ANY (ARRAY['building'::text, 'ready'::text, 'retired'::text, 'failed'::text]))
# Foreign key constraints:
#  ember_template_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  ember               | ember_ember_template_id_fkey               | (ember_template_id) REFERENCES ember_template(id)
#  ember_template_host | ember_template_host_ember_template_id_fkey | (ember_template_id) REFERENCES ember_template(id)
