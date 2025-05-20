# frozen_string_literal: true

require_relative "../model"

class UsageAlert < Sequel::Model
  many_to_one :project
  many_to_one :user, class: :Account, key: :user_id

  plugin ResourceMethods

  def trigger
    send_email
    update(last_triggered_at: Time.now)
  end

  def send_email
    Util.send_email(user.email, "Usage alert is triggered for project #{project.name}",
      greeting: "Hello #{user.name},",
      body: ["The usage alert, #{name}, you set for project #{project.name} (id: #{project.ubid}) has been triggered.",
        "Current cost: $#{project.current_invoice.content["cost"].to_f.round(2)}",
        "Please note that this alert is only for informational purposes and no action is taken automatically."],
      button_title: "See usage",
      button_link: "#{Config.base_url}#{project.path}/billing")
  end
end

# Table: usage_alert
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  project_id        | uuid                     | NOT NULL
#  name              | text                     | NOT NULL
#  limit             | integer                  | NOT NULL
#  user_id           | uuid                     | NOT NULL
#  last_triggered_at | timestamp with time zone | NOT NULL DEFAULT (now() - '42 days'::interval)
# Indexes:
#  usage_alert_pkey                         | PRIMARY KEY btree (id)
#  usage_alert_project_id_user_id_name_uidx | UNIQUE btree (project_id, user_id, name)
#  usage_alert_last_triggered_at_index      | btree (last_triggered_at)
# Foreign key constraints:
#  usage_alert_project_id_fkey | (project_id) REFERENCES project(id)
#  usage_alert_user_id_fkey    | (user_id) REFERENCES accounts(id)
