# frozen_string_literal: true

class Clover
  # GitHub App installations started by ubi gh connect come back here with a
  # state, and the user doesn't need to log in to the console. Instead, the
  # page shows a code that the user enters in ubi gh connect to finish.
  hash_branch(:github_connect_prefix, "callback") do |r|
    r.get true do
      @page_title = "Connect GitHub"
      @use_page_message = true
      @page_message = "GitHub connection failed"

      unless (request = GithubConnectRequest.with_state(typecast_params.str!("state")))
        @connect_error = "The link is invalid or expired. Run ubi gh connect again."
        next view "github/connect"
      end

      installation_id = typecast_params.str("installation_id")

      if typecast_params.str("setup_action") == "request"
        @connect_error = "The installation is waiting for approval from an administrator of the GitHub organization. After the approval, run ubi gh connect again."
        next view "github/connect"
      end

      begin
        access_token = Github.oauth_client.exchange_code_for_token(typecast_params.str("code"))[:access_token]
        installation_response = Github.user_installation(access_token, installation_id) if access_token
      rescue Faraday::ConnectionFailed, Octokit::Unauthorized => ex
        Clog.emit("GitHub connect callback failed", Util.exception_to_hash(ex, into: {github_connect_callback_failed: {id: installation_id, project_ubid: request.project.ubid}}))
      end

      unless installation_response
        @connect_error = "GitHub didn't confirm that you can manage the installation. Run ubi gh connect again."
        next view "github/connect"
      end

      if GithubInstallation.with_github_installation_id(installation_response[:id])
        @connect_error = "This GitHub installation is already connected to a Ubicloud project."
        next view "github/connect"
      end

      @page_message = "Finish in your terminal"
      @project_name = request.project.name
      @account_name = installation_response[:account][:login] || installation_response[:account][:name]
      @code = request.set_code(installation_response[:id])
      view "github/connect"
    end
  end
end
