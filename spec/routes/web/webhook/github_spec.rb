# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "github" do
  let(:installation) do
    prj = Project.create(name: "test-project")
    GithubInstallation.create(installation_id: 123, name: "test-user", type: "User", project_id: prj.id)
  end

  let(:runner) { GithubRunner.create(installation_id: installation.id, label: "ubicloud", repository_name: "my-repo", runner_id: 123, vm_id: "46683a25-acb1-4371-afe9-d39f303e44b4") }

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

    it "destroys installation when receive deleted action" do
      expect(Prog::Github::DestroyGithubInstallation).to receive(:assemble).with(installation)
      send_webhook("installation", {action: "deleted", installation: {id: installation.installation_id}})

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubInstallation[#{installation.ubid}] deleted"}.to_json)
    end
  end

  context "when workflow_job event" do
    it "fails if installation not exists" do
      send_webhook("workflow_job", workflow_job_payload(action: "queued", installation_id: 789))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered installation"}}.to_json)
    end

    it "fails if label not matched" do
      send_webhook("workflow_job", workflow_job_payload(action: "queued", workflow_job: workflow_job_object(label: "other")))

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
      GithubCustomLabel.create(installation_id: installation.id, name: "custom-label-1", alias_for: "ubicloud-standard-4")
      st = instance_double(Strand, id: runner.id)
      expect(Prog::Vm::GithubRunner).to receive(:assemble).with(installation, repository_name: "my-repo", label: "ubicloud-standard-4", actual_label: "custom-label-1", default_branch: "main").and_return(st)
      send_webhook("workflow_job", workflow_job_payload(action: "queued", workflow_job: workflow_job_object(label: "custom-label-1")))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubRunner[#{runner.ubid}] created"}.to_json)
    end

    it "creates runner when receive queued action" do
      st = instance_double(Strand, id: runner.id)
      expect(Prog::Vm::GithubRunner).to receive(:assemble).with(installation, repository_name: "my-repo", label: "ubicloud", actual_label: "ubicloud", default_branch: "main").and_return(st)

      send_webhook("workflow_job", workflow_job_payload(action: "queued"))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubRunner[#{runner.ubid}] created"}.to_json)
    end

    it "fails if not queued and runner_id is empty" do
      send_webhook("workflow_job", workflow_job_payload(action: "waiting", workflow_job: workflow_job_object(runner_id: nil)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "A workflow_job without runner_id"}}.to_json)
    end

    it "fails if runner not exists" do
      send_webhook("workflow_job", workflow_job_payload(action: "in_progress", workflow_job: workflow_job_object(runner_id: 789)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unregistered runner"}}.to_json)
    end

    it "updates job details of runner when receive in_progress action" do
      expect(Clog).to receive(:emit).with("runner_started").and_call_original
      runner
      send_webhook("workflow_job", workflow_job_payload(action: "in_progress", workflow_job: workflow_job_object(runner_id: runner.runner_id)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubRunner[#{runner.ubid}] picked job 232323"}.to_json)
      expect(runner.reload.workflow_job["id"]).to eq(232323)
    end

    it "destroys runner when receive completed action" do
      Strand.create_with_id(runner.id, prog: "Vm::GithubRunner", label: "start")

      send_webhook("workflow_job", workflow_job_payload(action: "completed", workflow_job: workflow_job_object(runner_id: runner.runner_id)))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({message: "GithubRunner[#{runner.ubid}] deleted"}.to_json)
      expect(SemSnap.new(runner.id).set?("destroy")).to be true
    end

    it "fails if unexpected action" do
      runner
      send_webhook("workflow_job", workflow_job_payload(action: "approved"))

      expect(page.status_code).to eq(200)
      expect(page.body).to eq({error: {message: "Unhandled workflow_job action"}}.to_json)
    end
  end

  def workflow_job_object(runner_id: 123, label: "ubicloud")
    {
      id: 232323,
      runner_id: runner_id,
      labels: [label],
      name: "test workflow job name",
      job_name: "test job name",
      run_id: 7777777,
      workflow_name: "test workflow name",
      head_branch: "test head branch",
      created_at: "2024-04-24T16:02:42Z",
      started_at: "2024-04-24T16:03:40Z"
    }
  end

  def workflow_job_payload(action:, installation_id: installation.installation_id, repository_name: "my-repo", workflow_job: workflow_job_object)
    {
      action: action,
      installation: {id: installation_id},
      repository: {full_name: repository_name, default_branch: "main"},
      workflow_job: workflow_job
    }
  end

  def send_webhook(event, data)
    data_json = data.to_json
    page.driver.post("/webhook/github",
      data_json,
      {
        "Content-Type" => "application/json",
        "HTTP_X_GITHUB_EVENT" => event,
        "HTTP_X_HUB_SIGNATURE_256" => "sha256=#{OpenSSL::HMAC.hexdigest("sha256", "secret", data_json)}"
      })
  end
end
