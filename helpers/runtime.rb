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

  def get_scope_from_github(runner, run_id)
    log_context = {runner_ubid: runner.ubid, repository_ubid: runner.repository.ubid, run_id: run_id}
    if run_id.nil? || run_id.empty?
      Clog.emit("The run_id is blank") { {runner_scope_failure: log_context} }
      return
    end

    Clog.emit("Get runner scope from GitHub API") { {get_runner_scope: log_context} }
    begin
      client = Github.installation_client(runner.installation.installation_id)
      jobs = client.workflow_run_jobs(runner.repository_name, run_id)[:jobs]
    rescue Octokit::ClientError, Octokit::ServerError, Faraday::ConnectionFailed => ex
      log_context[:expection] = Util.exception_to_hash(ex)
      Clog.emit("Could not list the jobs of the workflow run ") { {runner_scope_failure: log_context} }
      return
    end
    if (job = jobs.find { _1[:runner_name] == runner.ubid })
      job[:head_branch]
    else
      Clog.emit("The workflow run does not have given runner") { {runner_scope_failure: log_context} }
      nil
    end
  end
end
