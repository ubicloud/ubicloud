# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "policy") do |r|
    Authorization.authorize(@current_user.id, "Project:policy", @project.id)

    r.get true do
      # For UI simplicity, we are showing only one policy at the moment
      @policy = Serializers::AccessPolicy.serialize(@project.access_policies_dataset.where(managed: false).first)

      view "project/policy"
    end

    r.is String do |policy_ubid|
      policy = AccessPolicy.from_ubid(policy_ubid)

      unless policy
        response.status = 404
        r.halt
      end

      r.post true do
        body = r.params["body"]

        begin
          fail JSON::ParserError unless JSON.parse(body).is_a?(Hash)
        rescue JSON::ParserError
          flash["error"] = "The policy isn't a valid JSON object."
          return redirect_back_with_inputs
        end

        policy.update(body: body)

        flash["notice"] = "'#{policy.name}' policy updated for '#{@project.name}'"

        r.redirect "#{@project.path}/policy"
      end
    end
  end
end
