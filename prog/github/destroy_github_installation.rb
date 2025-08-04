# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Github::DestroyGithubInstallation < Prog::Base
  subject_is :github_installation

  def self.assemble(installation)
    Strand.create(
      prog: "Github::DestroyGithubInstallation",
      label: "start",
      stack: [{"subject_id" => installation.id}]
    )
  end

  label def before_run
    pop "github installation is destroyed" unless github_installation
  end

  label def start
    register_deadline(nil, 10 * 60)
    hop_delete_installation
  end

  label def delete_installation
    begin
      Github.app_client.delete_installation(github_installation.installation_id)
    rescue Octokit::NotFound
    end
    hop_destroy_resources
  end

  label def destroy_resources
    github_installation.repositories.map(&:incr_destroy)
    github_installation.runners.map do |runner|
      runner.incr_skip_deregistration
      runner.incr_destroy
    end
    hop_destroy
  end

  label def destroy
    nap 10 unless github_installation.runners_dataset.empty?
    nap 10 unless github_installation.repositories_dataset.empty?

    github_installation.destroy
    Clog.emit("GithubInstallation is deleted.") { github_installation }

    pop "github installation destroyed"
  end
end
