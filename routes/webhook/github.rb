# frozen_string_literal: true

class Clover
  hash_branch(:webhook_prefix, "github") do |r|
    r.post true do
      body = r.body.read
      next 401 unless check_signature(r.headers["x-hub-signature-256"], body)

      response.content_type = :json

      data = JSON.parse(body)
      case r.headers["x-github-event"]
      when "installation"
        handle_installation(data)
      when "workflow_job"
        handle_workflow_job(data)
      else
        error("Unhandled event")
      end
    end
  end

  def error(msg)
    {error: {message: msg}}
  end

  def success(msg)
    {message: msg}
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
      return error("Unregistered installation") unless installation
      return error("Inactive project") unless installation.project.active?

      Prog::Github::DestroyGithubInstallation.assemble(installation)
      return success("GithubInstallation[#{installation.ubid}] deleted")
    end

    error("Unhandled installation action")
  end

  def handle_workflow_job(data)
    unless (installation = GithubInstallation[installation_id: data["installation"]["id"]])
      return error("Unregistered installation")
    end

    unless (job = data["workflow_job"])
      Clog.emit("No workflow_job in the payload") { {workflow_job_missing: {installation_id: installation.id, action: data["action"]}} }
      return error("No workflow_job in the payload")
    end

    job_labels = job.fetch("labels")

    if (label = job_labels.find { Github.runner_labels.key?(it) })
      actual_label = label
    elsif (custom_label = GithubCustomLabel.first(installation_id: installation.id, name: job_labels))
      actual_label = custom_label.name
      label = custom_label.alias_for
    end

    repository_name = data["repository"]["full_name"]
    unless label
      Clog.emit("Unmatched label") { {unmatched_label: {repository_name:, labels: job_labels}} } if data["action"] == "queued"
      return error("Unmatched label")
    end

    if data["action"] == "queued"
      st = Prog::Vm::GithubRunner.assemble(
        installation,
        repository_name:,
        label:,
        actual_label:,
        default_branch: data["repository"]["default_branch"]
      )
      runner = GithubRunner[st.id]

      return success("GithubRunner[#{runner.ubid}] created")
    end

    unless (runner_id = job.fetch("runner_id"))
      return error("A workflow_job without runner_id")
    end

    runner = GithubRunner.first(
      installation_id: installation.id,
      repository_name:,
      runner_id:
    )

    return error("Unregistered runner") unless runner

    runner.this.update(workflow_job: Sequel.pg_jsonb(job.except("steps")))

    case data["action"]
    when "in_progress"
      runner.log_duration("runner_started", Time.parse(job["started_at"]) - Time.parse(job["created_at"]))
      success("GithubRunner[#{runner.ubid}] picked job #{job.fetch("id")}")
    when "completed"
      runner.incr_destroy

      success("GithubRunner[#{runner.ubid}] deleted")
    else
      error("Unhandled workflow_job action")
    end
  end
end
