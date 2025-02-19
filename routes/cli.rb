# frozen_string_literal: true

class Clover
  hash_branch("cli") do |r|
    r.post api? do
      response["content-type"] = "text/plain"

      unless (argv = r.POST["argv"]).is_a?(Array) && argv.all?(String)
        response.status = 400
        next "! Invalid request: No or invalid argv parameter provided"
      end

      project_id = env["clover.project_id"] = ApiKey.where(id: rodauth.session["pat_id"]).get(:project_id)
      env["clover.project_ubid"] = UBID.from_uuidish(project_id).to_s
      r.halt UbiCli.process(argv, env)
    end
  end
end
