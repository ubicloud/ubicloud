# frozen_string_literal: true

require_relative "../model"

class Account < Sequel::Model(:accounts)
  one_to_many :usage_alerts, key: :user_id
  one_to_many :api_keys, key: :owner_id, conditions: {owner_table: "accounts"}
  one_to_many :identities, class: :AccountIdentity
  many_to_many :projects, join_table: :access_tag, left_key: :hyper_tag_id, right_key: :project_id

  plugin :association_dependencies, usage_alerts: :destroy, projects: :nullify

  plugin ResourceMethods
  include SubjectTag::Cleanup

  alias_method :admin_label, :email

  def create_project_with_default_policy(name, default_policy: true)
    project = Project.create(name: name)
    add_project(project)

    if default_policy
      # Grant user Admin access
      admin_subject_tag = SubjectTag.create(project_id: project.id, name: "Admin")
      admin_subject_tag.add_subject(id)
      AccessControlEntry.create(project_id: project.id, subject_id: admin_subject_tag.id)

      # Also create a Member subject tag with access to member actions
      member_subject_tag = SubjectTag.create(project_id: project.id, name: "Member")
      AccessControlEntry.create(project_id: project.id, subject_id: member_subject_tag.id, action_id: ActionTag::MEMBER_ID)
    end

    project
  end

  def suspend
    update(suspended_at: Time.now)
    DB[:account_active_session_keys].where(account_id: id).delete(force: true)

    PaymentMethod.where(billing_info_id: projects_dataset.select(:billing_info_id)).update(fraud: true)
  end
end

# Table: accounts
# Columns:
#  id           | uuid                     | PRIMARY KEY
#  status_id    | integer                  | NOT NULL DEFAULT 1
#  email        | citext                   | NOT NULL
#  name         | text                     |
#  created_at   | timestamp with time zone | NOT NULL DEFAULT now()
#  suspended_at | timestamp with time zone |
# Indexes:
#  accounts_pkey        | PRIMARY KEY btree (id)
#  accounts_email_index | UNIQUE btree (email) WHERE status_id = ANY (ARRAY[1, 2])
# Check constraints:
#  valid_email | (email ~ '^[^,;@ \r\n]+@[^,@; \r\n]+\.[^,@; \r\n]+$'::citext)
# Foreign key constraints:
#  accounts_status_id_fkey | (status_id) REFERENCES account_statuses(id)
# Referenced By:
#  access_tag                        | access_tag_hyper_tag_id_fkey                      | (hyper_tag_id) REFERENCES accounts(id)
#  account_active_session_keys       | account_active_session_keys_account_id_fkey       | (account_id) REFERENCES accounts(id)
#  account_activity_times            | account_activity_times_id_fkey                    | (id) REFERENCES accounts(id)
#  account_authentication_audit_logs | account_authentication_audit_logs_account_id_fkey | (account_id) REFERENCES accounts(id)
#  account_email_auth_keys           | account_email_auth_keys_id_fkey                   | (id) REFERENCES accounts(id)
#  account_identities                | account_identities_account_id_fkey                | (account_id) REFERENCES accounts(id)
#  account_jwt_refresh_keys          | account_jwt_refresh_keys_account_id_fkey          | (account_id) REFERENCES accounts(id)
#  account_lockouts                  | account_lockouts_id_fkey                          | (id) REFERENCES accounts(id)
#  account_login_change_keys         | account_login_change_keys_id_fkey                 | (id) REFERENCES accounts(id)
#  account_login_failures            | account_login_failures_id_fkey                    | (id) REFERENCES accounts(id)
#  account_otp_keys                  | account_otp_keys_id_fkey                          | (id) REFERENCES accounts(id)
#  account_otp_unlocks               | account_otp_unlocks_id_fkey                       | (id) REFERENCES accounts(id)
#  account_password_change_times     | account_password_change_times_id_fkey             | (id) REFERENCES accounts(id)
#  account_password_hashes           | account_password_hashes_id_fkey                   | (id) REFERENCES accounts(id)
#  account_password_reset_keys       | account_password_reset_keys_id_fkey               | (id) REFERENCES accounts(id)
#  account_previous_password_hashes  | account_previous_password_hashes_account_id_fkey  | (account_id) REFERENCES accounts(id)
#  account_recovery_codes            | account_recovery_codes_id_fkey                    | (id) REFERENCES accounts(id)
#  account_remember_keys             | account_remember_keys_id_fkey                     | (id) REFERENCES accounts(id)
#  account_session_keys              | account_session_keys_id_fkey                      | (id) REFERENCES accounts(id)
#  account_sms_codes                 | account_sms_codes_id_fkey                         | (id) REFERENCES accounts(id)
#  account_verification_keys         | account_verification_keys_id_fkey                 | (id) REFERENCES accounts(id)
#  account_webauthn_keys             | account_webauthn_keys_account_id_fkey             | (account_id) REFERENCES accounts(id)
#  account_webauthn_user_ids         | account_webauthn_user_ids_id_fkey                 | (id) REFERENCES accounts(id)
#  usage_alert                       | usage_alert_user_id_fkey                          | (user_id) REFERENCES accounts(id)
