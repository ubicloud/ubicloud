# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::CheckGithubInstallationFraud do
  subject(:prog) { described_class.new(described_class.assemble(installation, account, 678)) }

  let(:account) { Account.create(email: "test@example.com") }
  let(:project) { Project.create(name: "test-project").tap { it.add_account(account) } }
  let(:installation) { GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: project.id) }

  describe "#before_run" do
    it "pops if the installation is destroyed" do
      installation.destroy
      expect { prog.before_run }.to exit({"msg" => "github installation is destroyed"})
    end

    it "does not pop if the installation exists" do
      expect { prog.before_run }.not_to raise_error
    end
  end

  describe "#start" do
    it "saves the GitHub account creation time and hops" do
      client = instance_double(Octokit::Client)
      expect(Github).to receive(:installation_client).with(123).and_return(client)
      github_created_at = Time.utc(2020, 1, 1)
      expect(client).to receive(:user).with(678).and_return({created_at: github_created_at})

      expect { prog.start }.to hop("check_github_account_age")
      expect(installation.reload.github_created_at).to eq(github_created_at)
    end
  end

  describe "#check_github_account_age" do
    let(:other_project) { Project.create(name: "other-project").tap { it.add_account(account) } }

    it "does not suspend the account if the GitHub account is old" do
      installation.update(github_created_at: installation.created_at - 11 * 60)

      expect { prog.check_github_account_age }.to exit({"msg" => "fraud check completed"})
      expect(account.reload.suspended_at).to be_nil
    end

    it "suspends the account if the GitHub account was created less than 10 minutes before the installation" do
      github_created_at = installation.created_at - 9 * 60
      installation.update(github_created_at:)
      expect(Clog).to receive(:emit).with("Suspended new GitHub installation", {suspended_new_github_installation: {installation_ubid: installation.ubid, account_ubid: account.ubid, github_created_at:}})

      expect { prog.check_github_account_age }.to exit({"msg" => "fraud check completed"})
      expect(account.reload.suspended_at).not_to be_nil
    end

    it "does not suspend a new GitHub account if any project of the account is verified" do
      other_project.update(reputation: "verified")
      installation.update(github_created_at: installation.created_at - 9 * 60)

      expect { prog.check_github_account_age }.to exit({"msg" => "fraud check completed"})
      expect(account.reload.suspended_at).to be_nil
    end

    it "does not suspend a new GitHub account if any project of the account has an earlier installation" do
      installation.update(github_created_at: installation.created_at - 9 * 60)
      GithubInstallation.create(installation_id: 456, name: "other-user", type: "User", project_id: other_project.id, created_at: installation.created_at - 60)

      expect { prog.check_github_account_age }.to exit({"msg" => "fraud check completed"})
      expect(account.reload.suspended_at).to be_nil
    end

    it "suspends a new GitHub account if the other installation was created at the same time or later" do
      installation.update(github_created_at: installation.created_at - 9 * 60)
      GithubInstallation.create(installation_id: 456, name: "other-user", type: "User", project_id: project.id, created_at: installation.created_at)
      GithubInstallation.create(installation_id: 789, name: "another-user", type: "User", project_id: other_project.id, created_at: installation.created_at + 60)

      expect { prog.check_github_account_age }.to exit({"msg" => "fraud check completed"})
      expect(account.reload.suspended_at).not_to be_nil
    end
  end
end
