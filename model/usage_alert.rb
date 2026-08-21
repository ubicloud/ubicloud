# frozen_string_literal: true

require_relative "../model"

class UsageAlert < Sequel::Model
  many_to_one :project, read_only: true
  many_to_one :user, class: :Account, read_only: true

  plugin ResourceMethods

  RESOURCE_TYPE_GROUPS = {
    "GithubRunner" => %w[GitHubRunnerMinutes],
  }.freeze

  dataset_module do
    def hard_limit_active
      where(hard_limit: true) { last_triggered_at >= Date.new(Time.now.year, Time.now.month, 1).to_time }
    end
  end

  def alert_cost(invoice)
    return invoice.content["cost"] unless resource_type

    line_item_types = RESOURCE_TYPE_GROUPS.fetch(resource_type)
    invoice.content["resources"]
      .flat_map { it["line_items"] }
      .sum { line_item_types.include?(it["resource_type"]) ? it["cost"] : 0 }
  end

  def trigger(current_cost)
    send_email(current_cost)
    update(last_triggered_at: Time.now)
  end

  def send_email(current_cost)
    action_sentence = if hard_limit
      scope = resource_type ? "#{resource_type} " : ""
      "Since this is a hard limit, creation of new #{scope}resources for this project is now blocked for the rest of this month."
    else
      "Please note that this alert is only for informational purposes and no action is taken automatically."
    end

    Util.send_email(user.email, "Usage alert is triggered for project #{project.name}",
      greeting: "Hello #{user.name},",
      body: ["The usage alert, #{name}, you set for project #{project.name} (id: #{project.ubid}) has been triggered.",
        "Current cost: $#{current_cost.to_f.round(2)}",
        action_sentence],
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
#  resource_type     | text                     |
#  hard_limit        | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  usage_alert_pkey                         | PRIMARY KEY btree (id)
#  usage_alert_project_id_user_id_name_uidx | UNIQUE btree (project_id, user_id, name)
#  usage_alert_last_triggered_at_index      | btree (last_triggered_at)
# Foreign key constraints:
#  usage_alert_project_id_fkey | (project_id) REFERENCES project(id)
#  usage_alert_user_id_fkey    | (user_id) REFERENCES accounts(id)
