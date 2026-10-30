# frozen_string_literal: true

require_relative "../../model"

class GithubConnectRequest < Sequel::Model
  TTL = 10 * 60
  CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  many_to_one :project, read_only: true

  plugin ResourceMethods, etc_type: true

  dataset_module do
    def active
      where { created_at > Time.now - TTL }
    end
  end

  def self.start(project_id)
    exclude { created_at > Time.now - TTL }.delete(force: true)
    create(project_id:, state: SecureRandom.urlsafe_base64(32))
  end

  def self.with_state(state)
    active.first(state:, code: nil)
  end

  def self.with_code(project_id, code)
    active.first(project_id:, code: code.upcase.delete("^A-Z0-9"))
  end

  def set_code(installation_id)
    code = Array.new(8) { CODE_CHARS[SecureRandom.random_number(CODE_CHARS.length)] }.join
    update(installation_id:, code:)
    "#{code[0, 4]}-#{code[4, 4]}"
  end
end

# Table: github_connect_request
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  project_id      | uuid                     | NOT NULL
#  state           | text                     | NOT NULL
#  installation_id | bigint                   |
#  code            | text                     |
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  github_connect_request_pkey      | PRIMARY KEY btree (id)
#  github_connect_request_state_key | UNIQUE btree (state)
# Foreign key constraints:
#  github_connect_request_project_id_fkey | (project_id) REFERENCES project(id)
