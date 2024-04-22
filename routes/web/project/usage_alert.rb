# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "usage-alert") do |r|
    Authorization.authorize(@current_user.id, "Project:billing", @project.id)

    r.post true do
      name = r.params["alert_name"]
      Validation.validate_short_text(name, "name")
      limit = Validation.validate_usage_limit(r.params["limit"])

      UsageAlert.create_with_id(project_id: @project.id, user_id: @current_user.id, name: name, limit: limit)

      r.redirect "#{@project.path}/billing"
    end

    r.is String do |usage_alert_ubid|
      usage_alert = UsageAlert.from_ubid(usage_alert_ubid)
      unless usage_alert
        response.status = 404
        return {message: "Usage alert is not found."}.to_json
      end

      r.delete true do
        usage_alert.destroy
        return {message: "Usage alert #{usage_alert.name} is deleted."}.to_json
      end
    end
  end
end
