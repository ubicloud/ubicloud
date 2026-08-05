# frozen_string_literal: true

require_relative "../model"

class RunCommand < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm

  plugin ResourceMethods

  # Tail-truncated to this size so a runaway command can't bloat the database.
  MAX_OUTPUT_BYTES = 64 * 1024

  def succeeded?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end

  def done?
    succeeded? || failed?
  end
end

# Table: run_command
# Columns:
#  id         | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(780)
#  command    | text                     | NOT NULL
#  status     | text                     | NOT NULL DEFAULT 'created'::text
#  output     | text                     |
#  created_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  run_at     | timestamp with time zone |
#  vm_id      | uuid                     | NOT NULL
# Indexes:
#  run_command_pkey        | PRIMARY KEY btree (id)
#  run_command_vm_id_index | btree (vm_id)
# Check constraints:
#  run_command_status_check | (status = ANY (ARRAY['created'::text, 'succeeded'::text, 'failed'::text]))
# Foreign key constraints:
#  run_command_vm_id_fkey | (vm_id) REFERENCES vm(id)
