# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "usage-alert") do |r|
    r.web do
      authorize("Project:billing", @project.id)

      r.post true do
        handle_validation_failure("project/billing")
        name = typecast_params.nonempty_str("alert_name")
        Validation.validate_short_text(name, "name")
        limit = typecast_params.pos_int!("limit")

        DB.transaction do
          ua = UsageAlert.create(project_id: @project.id, user_id: current_account_id, name:, limit:)
          audit_log(ua, "create")
        end

        r.redirect billing_path
      end

      r.delete :ubid_uuid do |id|
        next unless (usage_alert = @project.usage_alerts_dataset[id:])

        DB.transaction do
          usage_alert.destroy
          audit_log(usage_alert, "destroy")
        end

        flash["notice"] = "Usage alert #{usage_alert.name} is deleted."
        204
      end
    end
  end
end
