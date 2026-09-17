# frozen_string_literal: true

class Clover < Roda
  def get_runtime_jwt_payload
    return unless (v = request.env["HTTP_AUTHORIZATION"])

    jwt_token = v.sub(%r{\ABearer:?\s+}, "")
    begin
      JWT.decode(jwt_token, Config.clover_runtime_token_secret, true, {algorithm: "HS256"})[0]
    rescue JWT::DecodeError
    end
  end

  def github_runner_cache_scope(runner, run_id: nil, emit_workflow_error: true)
    if (cache_scope = runner.cache_scope)
      return cache_scope
    end

    if (cache_scope = runner.active_workflow_run&.cache_scope)
      runner.this.update(cache_scope:)
      return cache_scope
    end

    unless runner.run_id
      log_context = {runner_ubid: runner.ubid, repository_ubid: runner.repository.ubid, run_id:}
      unless run_id
        Clog.emit("The run_id is blank", {runner_scope_failure: log_context})
        return
      end

      Clog.emit("Get runner scope from GitHub API", {get_runner_scope: log_context})
      begin
        jobs = runner.installation.client(auto_paginate: true).workflow_run_jobs(runner.repository_name, run_id)[:jobs]
      rescue Octokit::ClientError, Octokit::ServerError, Faraday::ConnectionFailed, Faraday::TimeoutError => ex
        Util.exception_to_hash(ex, into: log_context)
        Clog.emit("Could not list the jobs of the workflow run ", {runner_scope_failure: log_context})
        return
      end

      if (job = jobs.find { it[:runner_name] == runner.ubid })
        update_github_runner_from_workflow_job(runner, JSON.parse(JSON.generate(job)))
        runner.reload
        if (cache_scope = runner.active_workflow_run&.cache_scope)
          runner.this.update(cache_scope:)
          return cache_scope
        end
      else
        Clog.emit("The workflow run does not have given runner", {runner_scope_failure: log_context})
        return
      end
    end

    begin
      run = runner.installation.client.workflow_run(runner.repository_name, runner.run_id)
    rescue Octokit::ClientError, Octokit::ServerError, Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => ex
      if emit_workflow_error
        Clog.emit("Could not fetch the workflow run", {runner_scope_failure: Util.exception_to_hash(ex, into: {runner_ubid: runner.ubid, repository_ubid: runner.repository.ubid, run_id:})})
      end

      return
    end

    # Deep convert to string keys
    run = JSON.parse(JSON.generate(run))

    cache_scope = runner.cache_scope = github_workflow_run_cache_scope(run, repository_name: runner.repository_name, run_id: runner.run_id, head_branch: runner.head_branch)
    runner.this.update(cache_scope:)
    cache_scope
  end
end
