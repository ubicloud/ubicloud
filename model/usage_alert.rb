# frozen_string_literal: true

require_relative "../model"

class UsageAlert < Sequel::Model
  many_to_one :project
  many_to_one :user, class: :Account, key: :user_id

  include ResourceMethods

  def self.ubid_type
    UBID::TYPE_ETC
  end

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
