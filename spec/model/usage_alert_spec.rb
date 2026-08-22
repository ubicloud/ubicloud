# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UsageAlert do
  let(:project) { Project.create(name: "project1") }
  let(:user) { Account.create(email: "user@example.com") }

  it "trigger sends email and updates last_triggered_at" do
    now = Time.now.round
    expect(Time).to receive(:now).and_return(now).at_least(:once)
    last_triggered_at = now - 42 * 24 * 60 * 60
    limit = 100
    alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit:, last_triggered_at:)

    expect(Util).to receive(:send_email)
    expect { alert.trigger(limit + 10) }.to change { alert.last_triggered_at }.from(last_triggered_at).to(now)
  end

  describe "#alert_cost" do
    let(:invoice) {
      Invoice.new(content: {
        "cost" => 42.0,
        "resources" => [
          {"line_items" => [
            {"resource_type" => "GitHubRunnerMinutes", "cost" => 10.0},
            {"resource_type" => "GitHubRunnerConcurrency", "cost" => 5.0},
            {"resource_type" => "GitHubCacheStorage", "cost" => 100.0},
            {"resource_type" => "VmVCpu", "cost" => 27.0},
          ]},
        ],
      })
    }

    it "returns total project cost when resource_type is nil" do
      alert = described_class.new(resource_type: nil)
      expect(alert.alert_cost(invoice)).to eq(42.0)
    end

    it "sums only the mapped line items for a scoped resource_type, excluding GitHubRunnerConcurrency" do
      alert = described_class.new(resource_type: "GithubRunner")
      expect(alert.alert_cost(invoice)).to eq(10.0)
    end
  end

  describe ".hard_limit_active" do
    it "excludes a soft (non-hard) alert regardless of last_triggered_at" do
      alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit: 100, hard_limit: false, last_triggered_at: Time.now)
      expect(described_class.where(id: alert.id).hard_limit_active.any?).to be false
    end

    it "includes a hard alert triggered this month" do
      alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit: 100, hard_limit: true, last_triggered_at: Time.now)
      expect(described_class.where(id: alert.id).hard_limit_active.any?).to be true
    end

    it "excludes a hard alert last triggered a previous month" do
      alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit: 100, hard_limit: true, last_triggered_at: Time.now - 45 * 24 * 60 * 60)
      expect(described_class.where(id: alert.id).hard_limit_active.any?).to be false
    end
  end

  describe "#send_email" do
    it "mentions blocking for a hard limit" do
      alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit: 100, resource_type: "GithubRunner", hard_limit: true)
      expect(Util).to receive(:send_email) do |_, _, body:, **|
        expect(body.join).to include("blocked for the rest of this month")
        expect(body.join).to include("GithubRunner resources")
      end
      alert.send_email(150)
    end

    it "mentions blocking without naming a resource type for a whole-project hard limit" do
      alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit: 100, hard_limit: true)
      expect(Util).to receive(:send_email) do |_, _, body:, **|
        expect(body.join).to include("blocked for the rest of this month")
        expect(body.join).to include("new resources for this project")
      end
      alert.send_email(150)
    end

    it "keeps the informational-only wording for a soft limit" do
      alert = described_class.create(project_id: project.id, user_id: user.id, name: "alert1", limit: 100)
      expect(Util).to receive(:send_email) do |_, _, body:, **|
        expect(body.join).to include("no action is taken automatically")
      end
      alert.send_email(150)
    end
  end
end
