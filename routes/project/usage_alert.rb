# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "usage-alert") do |r|
    r.web do
      authorize("Project:billing", @project.id)

      r.post true do
        name = r.params["alert_name"]
        Validation.validate_short_text(name, "name")
        limit = Validation.validate_usage_limit(r.params["limit"])

        DB.transaction do
          UsageAlert.create_with_id(project_id: @project.id, user_id: current_account_id, name: name, limit: limit)
        end

        r.redirect "#{@project.path}/billing"
      end

      r.is String do |usage_alert_ubid|
        next unless (usage_alert = UsageAlert.from_ubid(usage_alert_ubid)) && usage_alert.project_id == @project.id

        r.delete true do
          DB.transaction do
            usage_alert.destroy
          end

          flash["notice"] = "Usage alert #{usage_alert.name} is deleted."
          204
        end
      end
    end
  end
end
