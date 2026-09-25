# frozen_string_literal: true

class Prog::Github::GithubActiveWorkflowRunNexus < Prog::Base
  subject_is :github_active_workflow_run

  MAX_SECONDS = 60 * 60 * 24 * 35

  def self.assemble(installation:, repository_name:, create_date:, run_id:, run_attempt:, default_branch: nil, **)
    DB.transaction do
      unless (repository_id = GithubRepository.where(installation_id: installation.id, name: repository_name).get(:id))
        repository_id = Prog::Github::GithubRepositoryNexus.assemble(installation, repository_name, default_branch, update_last_job_at: false).id
      end

      workflow_run = GithubActiveWorkflowRun.new(installation_id: installation.id, repository_id:, repository_name:, create_date:, run_id:, run_attempt:, **)
      workflow_run.skip_auto_validations(:unique) do
        workflow_run.insert_conflict(target: [:repository_id, :run_id, :run_attempt], update: {repository_id:}).save_changes
      end
      Strand.new(prog: "Github::GithubActiveWorkflowRunNexus", label: "start", schedule: Time.now + 60 * 60) { it.id = workflow_run.id }
        .insert_conflict(target: :id).save_changes
    end
  end

  label def start
    hop_destroy if Time.now > github_active_workflow_run.created_at + MAX_SECONDS

    run = github_active_workflow_run
    begin
      data = run.installation.client.get("repos/#{run.repository_name}/actions/runs/#{run.run_id}/attempts/#{run.run_attempt}")
    rescue Octokit::ClientError => ex
      hop_destroy if ex.response_status == 404
      Clog.emit("Could not fetch the workflow run", {workflow_run_poll_failure: Util.exception_to_hash(ex, into: {run_ubid: run.ubid, repository_ubid: run.repository.ubid, run_id: run.run_id, run_attempt: run.run_attempt})})
    rescue Octokit::ServerError, Faraday::ConnectionFailed, Faraday::TimeoutError => ex
      Clog.emit("Could not fetch the workflow run", {workflow_run_poll_failure: Util.exception_to_hash(ex, into: {run_ubid: run.ubid, repository_ubid: run.repository.ubid, run_id: run.run_id, run_attempt: run.run_attempt})})
    else
      conclusion = data[:conclusion]
      status = data[:status]
      h = {status:, conclusion:}
      if status == "completed" && conclusion != "action_required"
        run.this.update(**h, completed_at: data[:updated_at])
        hop_destroy
      elsif run.status != status || run.conclusion != conclusion
        run.conclusion = conclusion
        run.this.update(h)
      end
    end

    nap(60 * 60 * ((run.conclusion == "action_required") ? 24 : 1))
  end

  label def destroy
    decr_destroy
    nap(10 * 60) unless github_active_workflow_run.active_runners_dataset.empty?

    unless github_active_workflow_run.completed_workflow_jobs_dataset.empty?
      duration = if github_active_workflow_run.completed_at && github_active_workflow_run.run_started_at
        (github_active_workflow_run.completed_at - github_active_workflow_run.run_started_at).ceil
      end
      begin
        DB.transaction(savepoint: true) do
          GithubCompletedWorkflowRun.insert(
            duration:,
            **github_active_workflow_run.values.slice(
              :repository_id,
              :run_id,
              :run_attempt,
              :create_date,
              :installation_id,
              :created_at,
              :run_started_at,
              :completed_at,
              :head_branch,
              :commit_hash,
              :head_repository_full_name,
              :event,
              :status,
              :conclusion,
              :display_title,
              :commit_message,
              :actor_login,
            ),
          )
        end
      rescue Sequel::DatabaseError => ex
        Clog.emit("failed to insert completed github workflow run", Util.exception_to_hash(ex, into: {github_completed_workflow_run_insert_failure: {github_active_workflow_run:}}))
      end
    end

    github_active_workflow_run.destroy
    pop("active workflow run finished")
  end
end
