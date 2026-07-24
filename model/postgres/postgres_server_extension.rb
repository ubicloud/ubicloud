# frozen_string_literal: true

require_relative "../../model"

class PostgresServerExtension < Sequel::Model
  many_to_one :postgres_server, read_only: true

  plugin ResourceMethods

  # Neither ready nor failed.
  ACTIVE_STATES = %w[install_pending installing sync_pending config_pending restart_pending verifying].freeze
  # States where installed_version reflects a completed install.
  INSTALLED_STATES = %w[sync_pending config_pending restart_pending verifying ready].freeze

  # Stamps last_transition_at (stall detection reads it) and clears last_error.
  def update_state(state, **attrs)
    update(state:, last_transition_at: Time.now, last_error: nil, **attrs)
  end
end

# Table: postgres_server_extension
# Columns:
#  id                 | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(733)
#  postgres_server_id | uuid                     | NOT NULL
#  name               | text                     | NOT NULL
#  target_version     | text                     |
#  installed_version  | text                     |
#  state              | text                     | NOT NULL DEFAULT 'install_pending'::text
#  last_transition_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  last_error         | text                     |
# Indexes:
#  postgres_server_extension_pkey                        | PRIMARY KEY btree (id)
#  postgres_server_extension_postgres_server_id_name_key | UNIQUE btree (postgres_server_id, name)
# Check constraints:
#  postgres_server_extension_state_check | (state = ANY (ARRAY['install_pending'::text, 'installing'::text, 'sync_pending'::text, 'config_pending'::text, 'restart_pending'::text, 'verifying'::text, 'ready'::text, 'failed'::text]))
# Foreign key constraints:
#  postgres_server_extension_postgres_server_id_fkey | (postgres_server_id) REFERENCES postgres_server(id) ON DELETE CASCADE
