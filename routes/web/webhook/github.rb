# frozen_string_literal: true

class CloverWeb
  hash_branch(:webhook_prefix, "github") do |r|
    r.post true do
      body = r.body.read
      unless check_signature(r.headers["x-hub-signature-256"], body)
        response.status = 401
        r.halt
      end

      response.headers["Content-Type"] = "application/json"

      data = JSON.parse(body)
      case r.headers["x-github-event"]
      when "installation"
        return handle_installation(data)
      when "workflow_job"
        return handle_workflow_job(data)
      end

      return error("Unhandled event")
    end
  end

  def error(msg)
    {error: {message: msg}}.to_json
  end

  def success(msg)
    {message: msg}.to_json
  end

  def check_signature(signature, body)
    return false unless signature
    method, actual_digest = signature.split("=")
    expected_digest = OpenSSL::HMAC.hexdigest(method, Config.github_app_webhook_secret, body)
    Rack::Utils.secure_compare(actual_digest, expected_digest)
  end

  def handle_installation(data)
    installation = GithubInstallation[installation_id: data["installation"]["id"]]
    case data["action"]
    when "deleted"
      unless installation
        return error("Unregistered installation")
      end
      installation.runners.each(&:incr_destroy)
      installation.destroy
      return success("GithubInstallation[#{installation.ubid}] deleted")
    end

    error("Unhandled installation action")
  end

  def handle_workflow_job(data)
    unless (installation = GithubInstallation[installation_id: data["installation"]["id"]])
      return error("Unregistered installation")
    end
    unless (label = data["workflow_job"]["labels"].find { Github.runner_labels.key?(_1) })
      return error("Unmatched label")
    end

    if data["action"] == "queued"
      st = Prog::Vm::GithubRunner.assemble(
        installation,
        repository_name: data["repository"]["full_name"],
        label: label
      )
      runner = GithubRunner[st.id]

      return success("GithubRunner[#{runner.ubid}] created")
    end

    runner = GithubRunner.first(
      installation_id: installation.id,
      repository_name: data["repository"]["full_name"],
      runner_id: data["workflow_job"]["runner_id"]
    )

    return error("Unregistered runner") unless runner

    case data["action"]
    when "in_progress"
      runner.update(
        job_id: data["workflow_job"]["id"],
        job_name: data["workflow_job"]["name"],
        run_id: data["workflow_job"]["run_id"],
        workflow_name: data["workflow_job"]["workflow_name"]
      )

      success("GithubRunner[#{runner.ubid}] picked job #{runner.job_id}")
    when "completed"
      runner.incr_destroy

      success("GithubRunner[#{runner.ubid}] deleted")
    else
      error("Unhandled workflow_job action")
    end
  end
end
