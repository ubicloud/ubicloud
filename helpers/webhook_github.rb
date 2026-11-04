# frozen_string_literal: true

class Clover
  def handle_webhook_github_installation(data)
    installation = GithubInstallation.with_github_installation_id(data.dig("installation", "id"))
    case data["action"]
    when "deleted"
      return {error: {message: "Unregistered installation"}} unless installation
      return {error: {message: "Inactive project"}} unless installation.project.active?

      Prog::Github::DestroyGithubInstallation.assemble(installation)
      return {message: "GithubInstallation[#{installation.ubid}] deleted"}
    end

    {error: {message: "Unhandled installation action"}}
  end

  def github_workflow_run_cache_scope(run, repository_name: run.dig("repository", "full_name"), run_id: run["id"], head_branch: run["head_branch"])
    head_repository_full_name = run.dig("head_repository", "full_name")
    if run["event"] == "pull_request" || (head_repository_full_name && head_repository_full_name != repository_name)
      "refs/pull/#{run.dig("pull_requests", 0, "number") || "unknown-run-#{run_id}"}/merge"
    else
      head_branch || ""
    end
  end

  def handle_webhook_github_workflow_run(data)
    case (action = data["action"])
    when "requested", "completed", "in_progress"
      nil
    else
      return {error: {message: "Unhandled workflow_run action"}}
    end

    unless (installation_id = data.dig("installation", "id")) && (installation = GithubInstallation.with_github_installation_id(installation_id))
      Clog.emit("Unregistered installation", {unregistered_installation: {installation_id:, repository_name: data.dig("repository", "full_name")}})
      return {error: {message: "Unregistered installation"}}
    end

    unless installation.has_billing_info?
      Clog.emit("Github workflow run webhook without billing info", {github_workflow_run_billing_info_missing: {installation_id: installation.id}})
      return {error: {message: "Must setup payment method before using Ubicloud runners"}}
    end

    if (run = data["workflow_run"])
      repository_name = run.dig("repository", "full_name")
      run_id = Integer(run["id"], exception: false)
      run_attempt = Integer(run["run_attempt"], exception: false)
      status = run["status"]
    end

    unless action && repository_name && run_id && run_attempt && status
      Clog.emit("No workflow_run in the payload or missing workflow_run data", {workflow_run_missing: {installation_id: installation.id, action:}})
      return {error: {message: "Missing or incomplete workflow_run in the payload"}}
    end

    unless action == "requested"
      unless (workflow_run = installation.active_workflow_runs_dataset.first(repository_name:, run_id:, run_attempt:))
        if action == "completed"
          return {error: {message: "Unregistered workflow_run"}}
        end
      end
    end

    if action == "requested" || (action == "in_progress" && workflow_run.nil?)
      head_branch = run["head_branch"]
      head_repository_full_name = run.dig("head_repository", "full_name")
      event = run["event"]
      run_started_at = run["run_started_at"]
      display_title = run["display_title"]&.[](0, 1024)
      commit_hash = run["head_sha"] || run.dig("head_commit", "id")
      commit_message = run.dig("head_commit", "message")&.[](0, 1024)
      actor_login = (run["actor"] || data["sender"])&.[]("login")

      begin
        create_date = Time.new(run["run_started_at"]).utc.to_date
      rescue
        nil
      end

      unless create_date && event && display_title && actor_login
        Clog.emit("No workflow_run in the payload or missing workflow_run data", {workflow_run_missing: {installation_id: installation.id, action:}})
        return {error: {message: "Missing or incomplete workflow_run in the payload"}}
      end

      workflow_run = Prog::Github::GithubActiveWorkflowRunNexus.assemble(
        installation:,
        repository_name:,
        default_branch: data.dig("repository", "default_branch"),
        run_id:,
        run_attempt:,
        head_branch:,
        head_repository_full_name:,
        create_date:,
        run_started_at:,
        event:,
        status:,
        display_title:,
        commit_hash:,
        commit_message:,
        actor_login:,
        cache_scope: github_workflow_run_cache_scope(run),
        conclusion: run["conclusion"],
      )

      if workflow_run
        return {message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}
      else
        return {error: {message: "Already completed workflow_run"}}
      end
    end

    if action == "completed"
      conclusion = run["conclusion"]
      if conclusion == "action_required"
        workflow_run.this.update(status:, conclusion:)
        {message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] awaiting approval"}
      else
        workflow_run.this.update(
          status:,
          completed_at: run["updated_at"],
          conclusion:,
        )
        workflow_run.incr_destroy
        {message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] scheduled for destruction"}
      end
    else # "in_progress"
      workflow_run.this.where(Sequel[conclusion: nil] | {conclusion: "action_required"}).update(status:, conclusion: nil)
      {message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] updated"}
    end
  end

  def update_github_runner_from_workflow_job(runner, job)
    runner.this.where(conclusion: nil).update(
      job_id: job["id"],
      run_id: job["run_id"],
      run_attempt: job["run_attempt"],
      head_branch: job["head_branch"],
      workflow_name: job["workflow_name"],
      job_name: job["name"],
      job_created_at: job["created_at"],
      job_started_at: job["started_at"],
      job_completed_at: job["completed_at"],
      status: job["status"],
      conclusion: job["conclusion"],
      workflow_job: Sequel.pg_jsonb(job.except("steps")),
    )
  end

  def handle_webhook_github_workflow_job(data)
    case (action = data["action"])
    when "queued", "completed", "in_progress"
      nil
    else
      return {error: {message: "Unhandled workflow_job action"}}
    end

    unless (installation_id = data.dig("installation", "id")) && (installation = GithubInstallation.with_github_installation_id(installation_id))
      Clog.emit("Unregistered installation", {unregistered_installation: {installation_id:, repository_name: data.dig("repository", "full_name")}})
      return {error: {message: "Unregistered installation"}}
    end

    unless (job = data["workflow_job"])
      Clog.emit("No workflow_job in the payload", {workflow_job_missing: {installation_id: installation.id, action:}})
      return {error: {message: "No workflow_job in the payload"}}
    end

    job_labels = job.fetch("labels")

    if (label = job_labels.find { Github.runner_labels.key?(it) })
      actual_label = label
    elsif (custom_label = installation.custom_labels_dataset.first(name: job_labels))
      actual_label = custom_label.name
      label = custom_label.alias_for
    end

    repository_name = data["repository"]["full_name"]
    unless label
      if action == "completed"
        Clog.emit("Unmatched label", {
          unmatched_label: {
            repository_name:,
            labels: job_labels,
            started_in: Time.new(job["started_at"]) - Time.new(job["created_at"]),
            completed_in: job["completed_at"] ? (Time.new(job["completed_at"]) - Time.new(job["started_at"])) : nil,
            conclusion: job["conclusion"],
          },
        })
      end
      return {error: {message: "Unmatched label"}}
    end

    if action == "queued"
      unless installation.has_billing_info?
        Clog.emit("Github runner queue request without billing info", {github_runner_billing_info_missing: {installation_id: installation.id}})
        return {error: {message: "Must setup payment method before using Ubicloud runners"}}
      end
      check_cutoff(project: installation.project, web: false, status: 200)

      runner = Prog::Github::GithubRunnerNexus.assemble(
        installation,
        repository_name:,
        label:,
        actual_label:,
        default_branch: data["repository"]["default_branch"],
      ).subject

      return {message: "GithubRunner[#{runner.ubid}] created"}
    end

    unless (runner_id = job.fetch("runner_id"))
      return {error: {message: "A workflow_job without runner_id"}}
    end

    runner = installation.runners_dataset.first(
      repository_name:,
      runner_id:,
    )

    return {error: {message: "Unregistered runner"}} unless runner

    update_github_runner_from_workflow_job(runner, job)

    if action == "in_progress"
      runner.log_duration("runner_started", Time.new(job["started_at"]) - Time.new(job["created_at"]))
      {message: "GithubRunner[#{runner.ubid}] picked job #{job.fetch("id")}"}
    else # "completed"
      runner.incr_destroy

      {message: "GithubRunner[#{runner.ubid}] deleted"}
    end
  end
end
