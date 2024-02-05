# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "policy") do |r|
    Authorization.authorize(@current_user.id, "Project:policy", @project.id)
    @serializer = Serializers::Api::AccessPolicy

    # Pagination hasn't been added on purpose to provide complete policy always
    r.get true do
      policy = serialize(@project.access_policies)

      serialize(policy)
    end

    r.is String do |policy_ubid|
      policy = AccessPolicy.from_ubid(policy_ubid)

      unless policy
        response.status = 404
        r.halt
      end

      r.put true do
        request_body_params = JSON.parse(request.body.read)

        body = request_body_params["body"]

        begin
          fail JSON::ParserError unless JSON.parse(body).is_a?(Hash)
        rescue JSON::ParserError
          response.status = 400
          return {code: 400, title: "Invalid Input", message: "The policy isn't a valid JSON object."}.to_json
        end

        policy.update(body: body)

        serialize(policy)
      end
    end
  end
end
