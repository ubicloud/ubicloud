# frozen_string_literal: true

class Clover
  hash_branch("mcp") do |r|
    r.is api? do
      no_authorization_needed
      no_audit_log

      project_id = env["clover.project_id"] = ApiKey.project_id_for_personal_access_token(rodauth.session["pat_id"])
      env["clover.project_ubid"] = UBID.to_ubid(project_id)
      r.halt UbiMcp.process(env)
    end
  end
end
