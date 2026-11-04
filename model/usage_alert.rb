# frozen_string_literal: true

require_relative "../model"

class UsageAlert < Sequel::Model
  many_to_one :project, read_only: true
  many_to_one :user, class: :Account, read_only: true

  plugin ResourceMethods
  plugin :update_or_create

  def trigger(current_cost)
    send_email(current_cost)
    project_dataset.update(cutoff_at: Sequel::CURRENT_TIMESTAMP) if cutoff
    update(last_triggered_at: Time.now)
  end

  def send_email(current_cost)
    if cutoff
      type = "Spending cutoff"
      body1 = "The spending cutoff"
      body2 = "New resource creation will no longer be allowed this month unless you increase or remove the spending cutoff."
    else
      type = "Usage alert is triggered"
      body1 = "The usage alert, #{name},"
      body2 = "Please note that this alert is only for informational purposes and no action is taken automatically."
    end

    Util.send_email(user.email, "#{type} for project #{project.name}",
      greeting: "Hello #{user.name},",
      body: ["#{body1} you set for project #{project.name} (id: #{project.ubid}) has been triggered.",
        "Current cost: $#{current_cost.to_f.round(2)}",
        body2],
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
#  cutoff            | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  usage_alert_pkey                         | PRIMARY KEY btree (id)
#  usage_alert_project_id_user_id_name_uidx | UNIQUE btree (project_id, user_id, name)
#  usage_alert_last_triggered_at_index      | btree (last_triggered_at)
#  usage_alert_user_id_index                | btree (user_id)
# Foreign key constraints:
#  usage_alert_project_id_fkey | (project_id) REFERENCES project(id)
#  usage_alert_user_id_fkey    | (user_id) REFERENCES accounts(id)
