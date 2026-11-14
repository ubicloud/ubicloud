# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:installation) do
    prj = Project.create(name: "test-project")
    GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: prj.id)
  end

  let(:runner) { GithubRunner.create(installation_id: installation.id, label: "ubicloud", repository_name: "my-repo", runner_id: 123, vm_id: "46683a25-acb1-4371-afe9-d39f303e44b4", location_id: Location::HETZNER_FSN1_ID) }
  let(:repository) { GithubRepository.create(installation_id: installation.id, name: "test-user/my-repo") }
  let(:workflow_run) do
    GithubActiveWorkflowRun.create(
      installation_id: installation.id,
      repository_id: repository.id,
      repository_name: "test-user/my-repo",
      run_id: 7777777,
      run_attempt: 1,
      create_date: Time.now.utc.to_date,
      head_branch: "test-branch",
      head_repository_full_name: "test-user/my-repo",
      event: "push",
      status: "queued",
      display_title: "CI",
      commit_message: "cm",
      actor_login: "al",
      cache_scope: "test-branch",
    )
  end

  before do
    allow(Config).to receive(:github_app_webhook_secret).and_return("secret")
  end

  it "fails if no signature header" do
    page.driver.post("/webhook/github")

    expect(page.status_code).to eq(401)
  end

  it "fails if signature digest tampered" do
    page.driver.post("/webhook/github", {}, {"HTTP_X_HUB_SIGNATURE_256" => "sha256=1234567890"})
    expect(page.status_code).to eq(401)
  end

  it "fails if signature does not use sha256" do
    page.driver.post("/webhook/github", {}, {"HTTP_X_HUB_SIGNATURE_256" => "md5=#{OpenSSL::HMAC.hexdigest("md5", "secret", "")}"})
    expect(page.status_code).to eq(401)
  end

  it "fails if signature algorithm is not supported by OpenSSL" do
    page.driver.post("/webhook/github", {}, {"HTTP_X_HUB_SIGNATURE_256" => "unsupported_hashing_method=abc123digest"})
    expect(page.status_code).to eq(401)
  end

  it "fails if signature has no algorithm prefix" do
    page.driver.post("/webhook/github", {}, {"HTTP_X_HUB_SIGNATURE_256" => "sha256"})
    expect(page.status_code).to eq(401)
  end

  it "fails if unexpected event" do
    send_webhook("repository", {})

    expect(page.status_code).to eq(200)
    expect(page.body).to eq({error: {message: "Unhandled event"}}.to_json)
  end

  context "when installation event" do
    it "fails if unexpected action" do
      send_webhook("installation", {action: "created", installation: {id: 1234}})

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unhandled installation action"}}.to_json)
    end

    it "fails if installation not exists when receive deleted action" do
      send_webhook("installation", {action: "deleted", installation: {id: 1234}})

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
    end

    it "fails if the project is inactive" do
      account = create_account.update(suspended_at: Time.now)
      account.add_project(installation.project)
      send_webhook("installation", {action: "deleted", installation: {id: installation.installation_id}})

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Inactive project"}}.to_json)
    end

    it "does not destroy the installation again if it is already being destroyed" do
      installation.this.update(created_at: GithubInstallation::CREATED_AT_CUTOFF - 1)
      send_webhook("installation", {action: "deleted", installation: {id: installation.installation_id}})

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
      expect(Strand.where(prog: "Github::DestroyGithubInstallation").count).to eq(0)
    end

    it "destroys installation when receive deleted action" do
      send_webhook("installation", {action: "deleted", installation: {id: installation.installation_id}})

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubInstallation[#{installation.ubid}] deleted"}.to_json)
      expect(Strand.where(prog: "Github::DestroyGithubInstallation").count).to eq(1)
      expect(GithubInstallation.with_github_installation_id(installation.installation_id)).to be_nil
    end

    it "does not start a second destroy for a repeated deleted action" do
      2.times { send_webhook("installation", {action: "deleted", installation: {id: installation.installation_id}}) }

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
      expect(Strand.where(prog: "Github::DestroyGithubInstallation").count).to eq(1)
    end
  end

  context "when workflow_job event" do
    it "fails if installation not exists" do
      expect(Clog).to receive(:emit).with("Unregistered installation", instance_of(Hash)).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "queued", installation_id: 789))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
    end

    it "fails without creating a runner if the installation is being destroyed" do
      installation.project.update(billing_info_id: BillingInfo.create(stripe_id: "0").id)
      installation.this.update(created_at: GithubInstallation::CREATED_AT_CUTOFF - 1)
      expect(Clog).to receive(:emit).with("Unregistered installation", instance_of(Hash)).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "queued"))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
      expect(GithubRunner.count).to eq(0)
      expect(GithubRepository.count).to eq(0)
    end

    it "fails if installation is missing from the payload" do
      expect(Clog).to receive(:emit).with("Unregistered installation", instance_of(Hash)).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "queued").except(:installation))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
    end

    it "fails if label not matched" do
      send_webhook("workflow_job", workflow_job_payload(action: "queued", workflow_job: workflow_job_object(label: "other")))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unmatched label"}}.to_json)
    end

    it "fails if label not matched and logs if completed" do
      expect(Clog).to receive(:emit).with("Unmatched label", instance_of(Hash)).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "completed", workflow_job: workflow_job_object(label: "other")))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unmatched label"}}.to_json)
    end

    it "fails if label not matched and logs even completed_at is nil" do
      expect(Clog).to receive(:emit).with("Unmatched label", instance_of(Hash)).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "completed", workflow_job: workflow_job_object(label: "other", completed_at: nil)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unmatched label"}}.to_json)
    end

    it "fails if workflow job is empty" do
      expect(Clog).to receive(:emit).at_least(:once).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "queued", workflow_job: nil))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "No workflow_job in the payload"}}.to_json)
    end

    it "uses custom label if label is an existing custom label" do
      billing_info_id = BillingInfo.create(stripe_id: "0").id
      installation.project.update(billing_info_id:)
      GithubCustomLabel.create(installation_id: installation.id, name: "custom-label-1", alias_for: "ubicloud-standard-4")
      send_webhook("workflow_job", workflow_job_payload(action: "queued", workflow_job: workflow_job_object(label: "custom-label-1")))

      expect(page.status_code).to eq(200)
      created_runner = GithubRunner.first(installation_id: installation.id, repository_name: "my-repo", label: "ubicloud-standard-4", actual_label: "custom-label-1")
      expect(created_runner).not_to be_nil
      expect(page.body).to eq({message: "GithubRunner[#{created_runner.ubid}] created"}.to_json)
    end

    it "creates runner when receive queued action" do
      billing_info_id = BillingInfo.create(stripe_id: "0").id
      installation.project.update(billing_info_id:)
      send_webhook("workflow_job", workflow_job_payload(action: "queued"))

      expect(page.status_code).to eq(200)
      created_runner = GithubRunner.first(installation_id: installation.id, repository_name: "my-repo", label: "ubicloud", actual_label: "ubicloud")
      expect(page.body).to eq({message: "GithubRunner[#{created_runner.ubid}] created"}.to_json)
    end

    it "does not create runner if project has hit spending cutoff" do
      billing_info_id = BillingInfo.create(stripe_id: "0").id
      installation.project.update(billing_info_id:, cutoff_at: Time.now)
      send_webhook("workflow_job", workflow_job_payload(action: "queued"))

      expect(page.status_code).to eq(200)
      expect(GithubRunner.first(installation_id: installation.id)).to be_nil
      expect(page.body).to eq({error: {code: 400, type: "InvalidRequest", message: "This project has been cut off from additional spending."}}.to_json)
    end

    it "does not create runner if there is no billing info" do
      expect(Clog).to receive(:emit).with("Github runner queue request without billing info", {github_runner_billing_info_missing: {installation_id: installation.id}}).and_call_original
      send_webhook("workflow_job", workflow_job_payload(action: "queued"))

      expect(page.status_code).to eq(200)
      created_runner = GithubRunner.first(installation_id: installation.id, repository_name: "my-repo", label: "ubicloud", actual_label: "ubicloud")
      expect(created_runner).to be_nil
      expect(page.body).to eq({error: {message: "Must setup payment method before using Ubicloud runners"}}.to_json)
    end

    it "fails if not queued and runner_id is empty" do
      send_webhook("workflow_job", workflow_job_payload(action: "in_progress", workflow_job: workflow_job_object(runner_id: nil)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "A workflow_job without runner_id"}}.to_json)
    end

    it "fails if runner not exists" do
      send_webhook("workflow_job", workflow_job_payload(action: "in_progress", workflow_job: workflow_job_object(runner_id: 789)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered runner"}}.to_json)
    end

    it "updates job details of runner when receive in_progress action" do
      expect(Clog).to receive(:emit).with("runner_started", instance_of(Hash)).and_call_original
      runner.update(repository_id: repository.id)
      send_webhook("workflow_job", workflow_job_payload(action: "in_progress", workflow_job: workflow_job_object(runner_id: runner.runner_id)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubRunner[#{runner.ubid}] picked job 232323"}.to_json)
      expect(runner.reload.workflow_job["id"]).to eq(232323)
      expect(runner.job_id).to eq(232323)
      expect(runner.run_id).to eq(7777777)
      expect(runner.run_attempt).to eq(1)
      expect(runner.head_branch).to eq("test head branch")
      expect(runner.workflow_name).to eq("test workflow name")
      expect(runner.status).to eq("queued")
      expect(workflow_run.active_runners).to eq [runner]
    end

    it "destroys runner when receive completed action" do
      Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "start")

      send_webhook("workflow_job", workflow_job_payload(action: "completed", workflow_job: workflow_job_object(runner_id: runner.runner_id, conclusion: "success")))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubRunner[#{runner.ubid}] deleted"}.to_json)
      expect(SemSnap.new(runner.id).set?("destroy")).to be true
      expect(runner.reload.conclusion).to eq("success")
    end

    it "fails if unexpected action, before checking the installation or payload" do
      ["approved", "waiting", nil].each do |action|
        send_webhook("workflow_job", workflow_job_payload(action:, installation_id: 789, workflow_job: nil))

        expect(page.status_code).to eq(200)
        expect(page.body).to eq({error: {message: "Unhandled workflow_job action"}}.to_json)
      end
    end
  end

  context "when workflow_run event" do
    before do
      installation.project.update(billing_info_id: BillingInfo.create(stripe_id: "0").id)
    end

    it "returns error if installation does not exist" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", installation_id: 789))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
    end

    it "returns error without creating a workflow run or repository if the installation is being destroyed" do
      installation.this.update(created_at: GithubInstallation::CREATED_AT_CUTOFF - 1)
      send_webhook("workflow_run", workflow_run_payload(action: "requested"))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
      expect(GithubActiveWorkflowRun.count).to eq(0)
      expect(GithubRepository.count).to eq(0)
    end

    it "returns error without creating a workflow run or repository if the project has no billing info" do
      installation.project.update(billing_info_id: nil)
      expect(Clog).to receive(:emit).with("Github workflow run webhook without billing info", {github_workflow_run_billing_info_missing: {installation_id: installation.id}}).and_call_original
      send_webhook("workflow_run", workflow_run_payload(action: "requested"))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Must setup payment method before using Ubicloud runners"}}.to_json)
      expect(GithubActiveWorkflowRun.count).to eq(0)
      expect(GithubRepository.count).to eq(0)
    end

    it "returns error if workflow_run is missing from the payload" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: nil))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Missing or incomplete workflow_run in the payload"}}.to_json)
    end

    it "returns error if workflow_run data is incomplete" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(event: nil)))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Missing or incomplete workflow_run in the payload"}}.to_json)
    end

    it "returns error if requested workflow_run has missing or invalid run_started_at, missing display_title, or no actor or sender" do
      [
        workflow_run_payload(action: "requested", workflow_run: workflow_run_object.merge(run_started_at: nil)),
        workflow_run_payload(action: "requested", workflow_run: workflow_run_object.merge(run_started_at: "bogus")),
        workflow_run_payload(action: "requested", workflow_run: workflow_run_object(display_title: nil)),
        workflow_run_payload(action: "requested", workflow_run: workflow_run_object.merge(actor: nil)).merge(sender: nil),
      ].each do |payload|
        send_webhook("workflow_run", payload)
        expect(page.status_code).to eq(200)
        expect(page.body).to eq({error: {message: "Missing or incomplete workflow_run in the payload"}}.to_json)
      end
      expect(GithubActiveWorkflowRun.count).to eq(0)
    end

    it "creates a workflow run when the received action is 'requested'" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested"))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777)
      expect(workflow_run).not_to be_nil
      expect(workflow_run.cache_scope).to eq("test-branch")
      expect(workflow_run.commit_hash).to eq("32eb7222f4676683fcec5dca08dc1218168801d5")
      expect(workflow_run.commit_message).to eq("cm")
      today = Time.now.utc.to_date
      expect(workflow_run.create_date).to eq(today)
      expect(workflow_run.run_started_at).to eq(Time.utc(today.year, today.month, today.day, 10, 20, 40))
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
      expect(workflow_run.repository.default_branch).to eq("main")
    end

    it "stores the conclusion when the requested workflow run requires approval" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(status: "completed", conclusion: "action_required")))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777)
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "uses the head_commit id for commit_hash when head_sha is null" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(head_sha: nil, head_commit: {id: "a" * 40, message: "cm"})))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777)
      expect(workflow_run.commit_hash).to eq("a" * 40)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "creates a workflow run with an empty cache_scope when the head branch is null and head_commit is null" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(head_branch: nil, head_commit: nil)))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777)
      expect(workflow_run.head_branch).to be_nil
      expect(workflow_run.cache_scope).to eq("")
      expect(workflow_run.commit_hash).to eq("32eb7222f4676683fcec5dca08dc1218168801d5")
      expect(workflow_run.commit_message).to be_nil
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "uses sender login for actor_login when actor is null" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object.merge(actor: nil)))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777)
      expect(workflow_run.actor_login).to eq("sl")
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "automatically handles duplicate workflow runs" do
      workflow_run
      expect { send_webhook("workflow_run", workflow_run_payload(action: "requested")) }
        .to change { Strand.count }.by(1)
        .and not_change { GithubActiveWorkflowRun.count }
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "does not create a workflow run when the received action is 'requested' for an already completed workflow run" do
      create_date = Time.now.utc.to_date
      GithubCompletedWorkflowRun.create_partition(create_date) unless GithubCompletedWorkflowRun.partition_days.include?(create_date)
      GithubCompletedWorkflowRun.insert(repository_id: repository.id, installation_id: installation.id, create_date:, created_at: Time.now, run_id: 7777777, run_attempt: 1, event: "push", status: "completed", conclusion: "success", display_title: "CI", actor_login: "al")

      expect { send_webhook("workflow_run", workflow_run_payload(action: "requested")) }
        .to not_change { GithubActiveWorkflowRun.count }
        .and not_change { Strand.count }
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Already completed workflow_run"}}.to_json)
    end

    it "uses pull request ref for cache_scope when the event is a pull_request" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(event: "pull_request", pull_requests: [{number: 41, base: {repo: {id: 2}}}, {number: 42, base: {repo: {id: 1}}}])))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777, run_attempt: 1)
      expect(workflow_run.cache_scope).to eq("refs/pull/42/merge")
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "uses unknown-run ref for cache_scope when no pull request has this repository as the base" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(event: "pull_request", pull_requests: [{number: 42, base: {repo: {id: 2}}}])))
      expect(page.status_code).to eq(200)
      expect(GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777, run_attempt: 1).cache_scope).to eq("refs/pull/unknown-run-7777777/merge")
    end

    it "uses unknown-run ref for cache_scope when the workflow run does not have a repository id" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(event: "pull_request", repository_id: nil, pull_requests: [{number: 42, base: {repo: {id: nil}}}])))
      expect(page.status_code).to eq(200)
      expect(GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777, run_attempt: 1).cache_scope).to eq("refs/pull/unknown-run-7777777/merge")
    end

    it "use unknown-run ref for cache_scope for a non-pull_request fork run" do
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: workflow_run_object(head_repository_full_name: "fork-user/my-repo", repository_full_name: "test-user/my-repo")))
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777, run_attempt: 1)
      expect(workflow_run.cache_scope).to eq("refs/pull/unknown-run-7777777/merge")
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "schedules workflow run destruction when the received action is 'completed'" do
      Strand.create_with_id(workflow_run, prog: "Github::GithubActiveWorkflowRunNexus", label: "start")
      send_webhook("workflow_run", workflow_run_payload(action: "completed", workflow_run: workflow_run_object(run_id: workflow_run.run_id, conclusion: "success")))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] scheduled for destruction"}.to_json)
      expect(workflow_run.destroy_set?).to be true
    end

    it "keeps the workflow run and does not schedule destruction when the received action is 'completed' with an action_required conclusion" do
      Strand.create_with_id(workflow_run, prog: "Github::GithubActiveWorkflowRunNexus", label: "start")
      expect { send_webhook("workflow_run", workflow_run_payload(action: "completed", workflow_run: workflow_run_object(status: "completed", conclusion: "action_required"))) }
        .not_to change { GithubActiveWorkflowRun.count }
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] awaiting approval"}.to_json)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")
      expect(workflow_run.completed_at).to be_nil
      expect(workflow_run.destroy_set?).to be false
    end

    it "handles a workflow run that requires approval through requested, completed, in_progress, and completed actions" do
      awaiting_approval = workflow_run_object(status: "completed", conclusion: "action_required")
      send_webhook("workflow_run", workflow_run_payload(action: "requested", workflow_run: awaiting_approval))
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777, run_attempt: 1)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")

      send_webhook("workflow_run", workflow_run_payload(action: "completed", workflow_run: awaiting_approval))
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] awaiting approval"}.to_json)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("action_required")
      expect(workflow_run.completed_at).to be_nil
      expect(workflow_run.destroy_set?).to be false

      send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(status: "in_progress")))
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] updated"}.to_json)
      workflow_run.reload
      expect(workflow_run.status).to eq("in_progress")
      expect(workflow_run.conclusion).to be_nil
      expect(workflow_run.destroy_set?).to be false

      send_webhook("workflow_run", workflow_run_payload(action: "completed", workflow_run: workflow_run_object(status: "completed", conclusion: "success")))
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] scheduled for destruction"}.to_json)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("success")
      expect(workflow_run.completed_at).not_to be_nil
      expect(workflow_run.destroy_set?).to be true
      expect(GithubActiveWorkflowRun.count).to eq(1)
    end

    it "returns error if workflow run does not exist when the received action is 'completed'" do
      send_webhook("workflow_run", workflow_run_payload(action: "completed", workflow_run: workflow_run_object(run_id: 999)))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered workflow_run"}}.to_json)
    end

    it "updates status for other known actions" do
      workflow_run
      send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(run_id: workflow_run.run_id, status: "in_progress")))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] updated"}.to_json)
      expect(workflow_run.reload.status).to eq("in_progress")
    end

    it "clears the action_required conclusion when an approved workflow run is in progress" do
      workflow_run.update(status: "completed", conclusion: "action_required")
      send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(run_id: workflow_run.run_id, status: "in_progress")))
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] updated"}.to_json)
      workflow_run.reload
      expect(workflow_run.status).to eq("in_progress")
      expect(workflow_run.conclusion).to be_nil
    end

    it "does not update status for in_progress action if the workflow run already has a final conclusion" do
      workflow_run.update(status: "completed", conclusion: "success")
      send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(run_id: workflow_run.run_id, status: "in_progress")))
      expect(page.status_code).to eq(200)
      workflow_run.reload
      expect(workflow_run.status).to eq("completed")
      expect(workflow_run.conclusion).to eq("success")
    end

    it "creates a workflow run when the received action is 'in_progress' and the workflow run does not exist" do
      expect { send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(status: "in_progress"))) }
        .to change { GithubActiveWorkflowRun.count }.by(1)
        .and change { Strand.count }.by(2)
      expect(page.status_code).to eq(200)
      workflow_run = GithubActiveWorkflowRun.first(installation_id: installation.id, run_id: 7777777, run_attempt: 1)
      expect(workflow_run.status).to eq("in_progress")
      expect(workflow_run.conclusion).to be_nil
      expect(workflow_run.cache_scope).to eq("test-branch")
      expect(workflow_run.create_date).to eq(Time.now.utc.to_date)
      expect(Strand[workflow_run.id].label).to eq("start")
      expect(page.body).to eq({message: "GithubActiveWorkflowRun[#{workflow_run.ubid}] created"}.to_json)
    end

    it "returns error if workflow run does not exist and the in_progress workflow_run data is incomplete" do
      expect { send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(status: "in_progress").merge(run_started_at: nil))) }
        .not_to change { GithubActiveWorkflowRun.count }
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Missing or incomplete workflow_run in the payload"}}.to_json)
    end

    it "does not create a workflow run when the received action is 'in_progress' for an already completed workflow run" do
      create_date = Time.now.utc.to_date
      GithubCompletedWorkflowRun.create_partition(create_date) unless GithubCompletedWorkflowRun.partition_days.include?(create_date)
      GithubCompletedWorkflowRun.insert(repository_id: repository.id, installation_id: installation.id, create_date:, created_at: Time.now, run_id: 7777777, run_attempt: 1, event: "push", status: "completed", conclusion: "success", display_title: "CI", actor_login: "al")

      expect { send_webhook("workflow_run", workflow_run_payload(action: "in_progress", workflow_run: workflow_run_object(status: "in_progress"))) }
        .to not_change { GithubActiveWorkflowRun.count }
        .and not_change { Strand.count }
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Already completed workflow_run"}}.to_json)
    end

    it "does not create a workflow run when the received action is 'completed' and the workflow run does not exist" do
      expect { send_webhook("workflow_run", workflow_run_payload(action: "completed", workflow_run: workflow_run_object(status: "completed", conclusion: "success"))) }
        .to not_change { GithubActiveWorkflowRun.count }
        .and not_change { GithubRepository.count }
      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered workflow_run"}}.to_json)
    end

    it "returns error for unknown action, before checking the installation or payload" do
      ["rerequested", "queued", nil].each do |action|
        send_webhook("workflow_run", workflow_run_payload(action:, installation_id: 789, workflow_run: nil))
        expect(page.status_code).to eq(200)
        expect(page.body).to eq({error: {message: "Unhandled workflow_run action"}}.to_json)
      end
    end
  end

  def workflow_run_object(run_id: 7777777, head_branch: "test-branch", display_title: "CI", event: "push", status: "queued", head_repository_full_name: "test-user/my-repo", repository_full_name: "test-user/my-repo", repository_id: 1, pull_requests: [], conclusion: nil, head_sha: "32eb7222f4676683fcec5dca08dc1218168801d5", head_commit: {id: "32eb7222f4676683fcec5dca08dc1218168801d5", message: "cm"})
    {
      id: run_id,
      run_attempt: 1,
      head_branch:,
      head_sha:,
      display_title:,
      event:,
      status:,
      conclusion:,
      created_at: (Time.now.utc.to_date - 1).strftime("%FT10:20:30Z"),
      run_started_at: Time.now.utc.to_date.strftime("%FT10:20:40Z"),
      updated_at: (Time.now - 1).to_s,
      head_repository: {full_name: head_repository_full_name},
      repository: {id: repository_id, full_name: repository_full_name},
      pull_requests:,
      head_commit:,
      actor: {login: "al"},
    }
  end

  def workflow_run_payload(action:, installation_id: installation.installation_id, default_branch: "main", workflow_run: workflow_run_object)
    {
      action:,
      installation: {id: installation_id},
      repository: {full_name: "test-user/my-repo", default_branch:},
      sender: {login: "sl"},
      workflow_run:,
    }
  end

  def workflow_job_object(runner_id: 123, label: "ubicloud", completed_at: "2024-04-24T16:13:40Z", conclusion: nil)
    {
      id: 232323,
      runner_id:,
      labels: [label],
      name: "test workflow job name",
      job_name: "test job name",
      run_id: 7777777,
      run_attempt: 1,
      workflow_name: "test workflow name",
      head_branch: "test head branch",
      created_at: "2024-04-24T16:02:42Z",
      started_at: "2024-04-24T16:03:40Z",
      completed_at:,
      status: "queued",
      conclusion:,
    }
  end

  def workflow_job_payload(action:, installation_id: installation.installation_id, repository_name: "my-repo", workflow_job: workflow_job_object)
    {
      action:,
      installation: {id: installation_id},
      repository: {full_name: repository_name, default_branch: "main"},
      workflow_job:,
    }
  end

  def send_webhook(event, data)
    data_json = data.to_json
    page.driver.post("/webhook/github",
      data_json,
      {
        "Content-Type" => "application/json",
        "HTTP_X_GITHUB_EVENT" => event,
        "HTTP_X_HUB_SIGNATURE_256" => "sha256=#{OpenSSL::HMAC.hexdigest("sha256", "secret", data_json)}",
      })
  end
end
