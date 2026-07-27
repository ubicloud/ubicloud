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

  def handle_webhook_github_workflow_job(data)
    unless (installation_id = data.dig("installation", "id")) && (installation = GithubInstallation.with_github_installation_id(installation_id))
      Clog.emit("Unregistered installation", {unregistered_installation: {installation_id:, repository_name: data.dig("repository", "full_name")}})
      return {error: {message: "Unregistered installation"}}
    end

    unless (job = data["workflow_job"])
      Clog.emit("No workflow_job in the payload", {workflow_job_missing: {installation_id: installation.id, action: data["action"]}})
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
      if data["action"] == "completed"
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

    if data["action"] == "queued"
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

    runner.this.update(workflow_job: Sequel.pg_jsonb(job.except("steps")))

    case data["action"]
    when "in_progress"
      runner.log_duration("runner_started", Time.new(job["started_at"]) - Time.new(job["created_at"]))
      {message: "GithubRunner[#{runner.ubid}] picked job #{job.fetch("id")}"}
    when "completed"
      runner.incr_destroy

      {message: "GithubRunner[#{runner.ubid}] deleted"}
    else
      {error: {message: "Unhandled workflow_job action"}}
    end
  end
end
