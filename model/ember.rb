# frozen_string_literal: true

require_relative "../model"

# One micro-VM in a slot on a host, restored from a template snapshot and
# backed by a detachable volume.
#
# An ember is obtainable in well under a second and costs nothing while it is
# paused, and none of that depends on what runs inside it. What does run
# inside is the business of a workload: a class named after it, <Workload>Ember,
# whose row shares this one's id.
#
# The tenant boundary is the VM rather than anything inside the guest, so a
# tenant may be root in their own ember and still reach nothing in another.
class Ember < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location
  many_to_one :vm_host
  many_to_one :ember_template
  one_to_one :detachable_volume, key: :owner_id

  dataset_module Pagination

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :pause, :resume, :checkup

  def running? = state == "running"

  def paused? = state == "paused"

  def display_state
    return "destroying" if destroy_set?
    state
  end

  def expired?
    !expires_at.nil? && Time.now > expires_at
  end

  # An ember is idle when nothing has touched it for longer than its timeout.
  # Whatever serves the workload reports activity; until it has, creation
  # counts as activity.
  def idle?
    return false unless running?
    Time.now - last_activity_at > idle_timeout_seconds
  end

  # What the state label shows. The states a tenant cares about are running,
  # paused and on its way to one of them.
  def display_color
    case display_state
    when "running" then "bg-green-100 text-green-800"
    when "paused" then "bg-slate-100 text-slate-800"
    when "destroying" then "bg-red-100 text-red-800"
    else "bg-yellow-100 text-yellow-800"
    end
  end

  def hostname(suffix)
    "#{ubid}.#{suffix}"
  end

  def self.workload_class(workload)
    Object.const_get("#{workload.capitalize}Ember")
  rescue NameError
    raise "unknown ember workload: #{workload}"
  end

  def workload = ember_template.workload

  def workload_row = Ember.workload_class(workload)[id]

  def guest_config = workload_row.guest_config
end

# Table: ember
# Columns:
#  id                   | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(396)
#  created_at           | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id           | uuid                     | NOT NULL
#  location_id          | uuid                     | NOT NULL
#  name                 | text                     | NOT NULL
#  state                | text                     | NOT NULL DEFAULT 'creating'::text
#  generation           | integer                  | NOT NULL DEFAULT 0
#  state_changed_at     | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_host_id           | uuid                     |
#  slot                 | integer                  |
#  ip6                  | inet                     |
#  ember_template_id    | uuid                     | NOT NULL
#  memory_mib           | integer                  | NOT NULL DEFAULT 384
#  cpu_percent_limit    | integer                  | NOT NULL DEFAULT 50
#  idle_timeout_seconds | integer                  | NOT NULL DEFAULT 300
#  last_activity_at     | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  last_started_at      | timestamp with time zone |
#  last_paused_at       | timestamp with time zone |
#  expires_at           | timestamp with time zone |
#  protected            | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  ember_pkey                    | PRIMARY KEY btree (id)
#  ember_project_id_name_uidx    | UNIQUE btree (project_id, name)
#  ember_vm_host_slot_uidx       | UNIQUE btree (vm_host_id, slot) WHERE slot IS NOT NULL
#  ember_expires_at_idx          | btree (expires_at)
#  ember_state_last_activity_idx | btree (state, last_activity_at)
# Check constraints:
#  ember_state_check | (state = ANY (ARRAY['creating'::text, 'running'::text, 'pausing'::text, 'paused'::text, 'resuming'::text, 'destroying'::text]))
# Foreign key constraints:
#  ember_ember_template_id_fkey | (ember_template_id) REFERENCES ember_template(id)
#  ember_location_id_fkey       | (location_id) REFERENCES location(id)
#  ember_project_id_fkey        | (project_id) REFERENCES project(id)
#  ember_vm_host_id_fkey        | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  postgres_ember | postgres_ember_id_fkey | (id) REFERENCES ember(id) ON DELETE CASCADE
