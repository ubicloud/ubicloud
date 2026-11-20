# frozen_string_literal: true

class Prog::Github::CheckGithubInstallationFraud < Prog::Base
  subject_is :github_installation
  frame_reader :account_id, :github_account_id

  NEW_GITHUB_ACCOUNT_AGE = 6 * 60 * 60

  def self.assemble(installation, account, github_account_id)
    Strand.create(
      prog: "Github::CheckGithubInstallationFraud",
      label: "start",
      stack: [{"subject_id" => installation.id, "account_id" => account.id, "github_account_id" => github_account_id}],
    )
  end

  label def before_run
    pop "github installation is destroyed" unless github_installation
  end

  label def start
    github_installation.update(github_created_at: github_installation.client.user(github_account_id)[:created_at])
    hop_check_github_account_age
  end

  label def check_github_account_age
    account = Account[account_id]
    installed_at = github_installation.created_at
    github_created_at = github_installation.github_created_at
    if installed_at - github_created_at < NEW_GITHUB_ACCOUNT_AGE &&
        account.projects_dataset.where(reputation: "verified").empty? &&
        GithubInstallation.where(project_id: account.projects_dataset.select(:id)).where { created_at < installed_at }.empty?
      Clog.emit("Suspended new GitHub installation", {suspended_new_github_installation: {installation_ubid: github_installation.ubid, account_ubid: account.ubid, github_created_at:}})
      account.suspend(send_email: false)
    end

    pop "fraud check completed"
  end
end
