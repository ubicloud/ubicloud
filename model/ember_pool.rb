# frozen_string_literal: true

require_relative "../model"

# The warm pool of blank embers for one location.
#
# A blank is an ember that has already been restored against a fresh volume and
# is waiting to be claimed, which turns a create into a password change. The
# pool is owned by the location rather than by a host so that the target does
# not move every time a host is added or drained: what a tenant waits on is a
# blank *somewhere* nearby, not a blank on any particular machine.
class EmberPool < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :location, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :refill

  # Hosts in this location that can currently hold a blank.
  def hosts_dataset
    VmHost.ember_accepting(location_id:)
  end

  def blanks_held
    hosts_dataset.all.sum { it.ember.blank_slots }
  end
end

# Table: ember_pool
# Columns:
#  id          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(402)
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  location_id | uuid                     | NOT NULL
#  workload    | text                     | NOT NULL
#  target      | integer                  | NOT NULL DEFAULT 4
#  enabled     | boolean                  | NOT NULL DEFAULT true
# Indexes:
#  ember_pool_pkey                   | PRIMARY KEY btree (id)
#  ember_pool_location_workload_uidx | UNIQUE btree (location_id, workload)
# Foreign key constraints:
#  ember_pool_location_id_fkey | (location_id) REFERENCES location(id)
