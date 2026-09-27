# frozen_string_literal: true

require_relative "../model"

# Tracks which hosts have built which template. Every host builds its own
# copy rather than fetching another's.
class EmberTemplateHost < Sequel::Model
  many_to_one :ember_template
  many_to_one :vm_host

  unrestrict_primary_key

  def ready?
    state == "ready"
  end
end

# Table: ember_template_host
# Primary Key: (ember_template_id, vm_host_id)
# Columns:
#  ember_template_id | uuid |
#  vm_host_id        | uuid |
#  state             | text | NOT NULL DEFAULT 'building'::text
# Indexes:
#  ember_template_host_pkey           | PRIMARY KEY btree (ember_template_id, vm_host_id)
#  ember_template_host_vm_host_id_idx | btree (vm_host_id)
# Check constraints:
#  ember_template_host_state_check | (state = ANY (ARRAY['building'::text, 'ready'::text, 'failed'::text]))
# Foreign key constraints:
#  ember_template_host_ember_template_id_fkey | (ember_template_id) REFERENCES ember_template(id)
#  ember_template_host_vm_host_id_fkey        | (vm_host_id) REFERENCES vm_host(id)
