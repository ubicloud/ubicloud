# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Ember do
  let(:ember) { create_ember }

  it "generates cc-prefixed ubids" do
    expect(ember.ubid).to start_with("cc")
  end

  describe "state" do
    it "reports running and paused" do
      ember.update(state: "running")
      expect(ember).to be_running
      expect(ember).not_to be_paused
      ember.update(state: "paused")
      expect(ember).to be_paused
      expect(ember).not_to be_running
    end

    it "shows destroying once the semaphore is set, whatever the column says" do
      Strand.create_with_id(ember, prog: "Ember::Nexus", label: "wait")
      ember.update(state: "running")
      expect(ember.display_state).to eq("running")
      ember.incr_destroy
      expect(ember.reload.display_state).to eq("destroying")
    end

    it "has a label colour for every state it can be in" do
      Strand.create_with_id(ember, prog: "Ember::Nexus", label: "wait")
      ember.update(state: "running")
      expect(ember.display_color).to include("green")
      ember.update(state: "paused")
      expect(ember.display_color).to include("slate")
      ember.update(state: "creating")
      expect(ember.display_color).to include("yellow")
      ember.incr_destroy
      expect(ember.reload.display_color).to include("red")
    end
  end

  describe "#expired?" do
    it "never expires without an expiry" do
      expect(ember).not_to be_expired
    end

    it "expires once its deadline passes" do
      ember.update(expires_at: Time.now - 1)
      expect(ember).to be_expired
      ember.update(expires_at: Time.now + 3600)
      expect(ember).not_to be_expired
    end
  end

  describe "#idle?" do
    it "is not idle while it has been touched recently" do
      ember.update(state: "running", last_activity_at: Time.now)
      expect(ember).not_to be_idle
    end

    it "is idle once nothing has touched it for longer than its timeout" do
      ember.update(state: "running", last_activity_at: Time.now - 301)
      expect(ember).to be_idle
    end

    it "is never idle when it is not running" do
      ember.update(state: "paused", last_activity_at: Time.now - 100_000)
      expect(ember).not_to be_idle
    end
  end

  it "builds the hostname from the ubid and the location's suffix" do
    expect(ember.hostname("pgc.ubicloud.app"))
      .to eq("#{ember.ubid}.pgc.ubicloud.app")
  end

  describe "workload" do
    it "is the template's" do
      expect(ember.workload).to eq(ember.ember_template.workload)
    end

    # The host takes the guest configuration as an opaque blob; the workload row
    # is the only thing that knows what goes in it.
    it "refuses a workload it has not been taught about" do
      ember.ember_template.update(workload: "runner")
      expect { ember.reload.guest_config }.to raise_error(RuntimeError, /unknown ember workload: runner/)
    end
  end
end
