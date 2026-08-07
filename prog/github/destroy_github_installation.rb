# frozen_string_literal: true

class Prog::Github::DestroyGithubInstallation < Prog::Base
  subject_is :github_installation
  frame_reader :delete_from_github

  def self.assemble(installation, delete_from_github: true)
    DB.transaction do
      installation.lock!(:no_key_update)
      installation.update(state: "deleting") if installation.active?

      legacy_strand = Strand
        .where(prog: "Github::DestroyGithubInstallation")
        .where(Sequel.pg_jsonb_op(:stack).contains([{"subject_id" => installation.id}]))
        .first
      strand = Strand[installation.id] || legacy_strand || Strand.create_with_id(
        installation,
        prog: "Github::DestroyGithubInstallation",
        label: "start",
        stack: [{"delete_from_github" => delete_from_github}],
      )
      fail "GitHub installation has an unexpected strand" unless strand.prog == "Github::DestroyGithubInstallation"

      signal_resources(installation)
      strand
    end
  end

  def self.signal_resources(installation)
    runner_ids = installation.runners_dataset.select(:id)
    signal_unless_set(runner_ids, "skip_deregistration")
    signal_unless_set(runner_ids, "destroy")
    signal_unless_set(installation.repositories_dataset.select(:id), "destroy")
  end

  def self.signal_unless_set(ids, name)
    unset_ids = Strand.where(id: ids).exclude(id: Semaphore.where(name:).select(:strand_id)).select(:id)
    Semaphore.incr(unset_ids, name)
  end

  label def before_run
    pop "github installation is destroyed" unless github_installation
    github_installation.lock!(:no_key_update)
    github_installation.update(state: "deleting") if github_installation.active?
  end

  label def start
    register_deadline(nil, 10 * 60)
    hop_delete_installation
  end

  label def delete_installation
    hop_destroy_resources if delete_from_github == false

    begin
      Github.app_client.delete_installation(github_installation.installation_id)
    rescue Octokit::NotFound
      nil
    end
    hop_destroy_resources
  end

  label def destroy_resources
    self.class.signal_resources(github_installation)
    hop_wait_resource_destroy
  end

  label def wait_resource_destroy
    self.class.signal_resources(github_installation)
    nap 10 unless github_installation.runners_dataset.empty?
    nap 10 unless github_installation.repositories_dataset.empty?

    Firewall.first(github_installation_id: github_installation.id)&.destroy
    if (subnet = PrivateSubnet.first(github_installation_id: github_installation.id))
      subnet.incr_destroy unless subnet.destroy_set?
      hop_wait_network_destroy
    end

    finish
  end

  label def wait_network_destroy
    if (subnet = PrivateSubnet.first(github_installation_id: github_installation.id))
      subnet.incr_destroy unless subnet.destroy_set?
      nap 10
    end

    finish
  end

  def finish
    github_installation.destroy
    Clog.emit("GithubInstallation is deleted.", github_installation)

    pop "github installation destroyed"
  end
end
