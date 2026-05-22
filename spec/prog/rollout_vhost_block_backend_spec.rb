# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutVhostBlockBackend do
  subject(:nx) { described_class.new(st) }

  let(:version) { "v0.4.2" }
  let(:st) {
    vm_hosts
    described_class.assemble(version:)
  }

  let(:gh_x64_hosts) {
    (1..10).map do |i|
      create_vm_host(
        created_at: Time.utc(2024, 1, i),
        arch: "x64",
        location_id: Location::GITHUB_RUNNERS_ID,
      )
    end
  }
  let(:gh_arm64_hosts) {
    (1..10).map do |i|
      create_vm_host(
        created_at: Time.utc(2024, 2, i),
        arch: "arm64",
        location_id: Location::GITHUB_RUNNERS_ID,
      )
    end
  }
  let(:other_hosts) {
    (1..10).map do |i|
      create_vm_host(
        created_at: Time.utc(2024, 3, i),
        arch: "x64",
        location_id: Location::HETZNER_FSN1_ID,
      )
    end
  }
  let(:vm_hosts) { gh_x64_hosts + gh_arm64_hosts + other_hosts }

  describe ".assemble" do
    it "creates a strand seeded for the gh_runner phase, wave 0, immediately runnable" do
      expect(st.prog).to eq("RolloutVhostBlockBackend")
      expect(st.label).to eq("start")
      frame = st.stack.first
      expect(frame["version"]).to eq(version)
      expect(frame["phase"]).to eq("gh_runner")
      expect(frame["wave_index"]).to eq(0)
      expect(frame["next_wave_time"]).to be_within(5).of(Time.now.to_i)
      expect(frame["completed"]).to eq([])
    end

    it "rejects unsupported versions" do
      expect { described_class.assemble(version: "v9.9.9") }.to raise_error(/Unsupported version/)
    end
  end

  describe ".supported_versions" do
    it "returns only versions present on every required arch, newest first" do
      stub_const(
        "VhostBlockBackend::SHA256_BY_VERSION_AND_ARCH",
        {
          ["v0.4.2", "x64"] => "a", ["v0.4.2", "arm64"] => "b",
          ["v0.3.1", "x64"] => "c", ["v0.3.1", "arm64"] => "d",
          ["v0.4.1", "x64"] => "e",
        }.freeze,
      )
      expect(described_class.supported_versions).to eq(["v0.4.2", "v0.3.1"])
    end
  end

  describe "#before_run" do
    it "naps when pause semaphore is set" do
      nx.incr_pause
      expect { nx.before_run }.to nap(60 * 60)
    end

    it "falls through to super when pause is not set" do
      expect { nx.before_run }.not_to raise_error
    end
  end

  describe "#start" do
    it "hops to run_wave" do
      expect { nx.start }.to hop("run_wave")
    end
  end

  describe "#run_wave" do
    it "naps until next_wave_time when in the future" do
      refresh_frame(nx, new_values: {"next_wave_time" => Time.now.to_i + 100})
      expect { nx.run_wave }.to nap(90..110)
    end

    it "installs on 10% of gh-runner hosts stratified by arch and hops to wait_wave" do
      vm_hosts
      ds = Strand.where(prog: "Storage::SetupVhostBlockBackend", label: "start")
      expect { nx.run_wave }.to hop("wait_wave").and change { ds.count }.from(0).to(2)
      subject_ids = ds.select_map(:stack).map { it[0]["subject_id"] }
      expect(subject_ids).to contain_exactly(gh_x64_hosts.first.id, gh_arm64_hosts.first.id)
    end

    it "skips hosts that already have this version installed" do
      vm_hosts
      VhostBlockBackend.create(vm_host_id: gh_x64_hosts.first.id, version:, allocation_weight: 0)
      ds = Strand.where(prog: "Storage::SetupVhostBlockBackend", label: "start")
      expect { nx.run_wave }.to hop("wait_wave").and change { ds.count }.from(0).to(1)
      expect(ds.get(:stack)[0]["subject_id"]).to eq gh_arm64_hosts.first.id
    end

    it "stratifies the 40% wave to 4 hosts per arch" do
      vm_hosts
      refresh_frame(nx, new_values: {"wave_index" => 1})
      ds = Strand.where(prog: "Storage::SetupVhostBlockBackend", label: "start")
      expect { nx.run_wave }.to hop("wait_wave").and change { ds.count }.from(0).to(8)
      subject_ids = ds.select_map(:stack).map { it[0]["subject_id"] }
      expect(subject_ids).to match_array(
        gh_x64_hosts.first(4).map(&:id) + gh_arm64_hosts.first(4).map(&:id),
      )
    end

    it "picks only non-gh-runner hosts in non_gh_runner phase" do
      vm_hosts
      refresh_frame(nx, new_values: {"phase" => "non_gh_runner", "wave_index" => 0})
      ds = Strand.where(prog: "Storage::SetupVhostBlockBackend", label: "start")
      expect { nx.run_wave }.to hop("wait_wave").and change { ds.count }.from(0).to(2)
      subject_ids = ds.select_map(:stack).map { it[0]["subject_id"] }
      expect(subject_ids).to match_array(other_hosts.first(2).map(&:id))
    end
  end

  describe "#wait_wave" do
    it "naps when child strands are still running" do
      Strand.create(prog: "Storage::SetupVhostBlockBackend", label: "start", parent_id: st.id, lease: Time.now + 100)
      expect { nx.wait_wave }.to nap(120)
    end

    it "records completed subjects and hops to advance_wave when children have exited" do
      vm_host_id = VmHost.generate_uuid
      Strand.create(prog: "Storage::SetupVhostBlockBackend", label: "start", parent_id: st.id,
        exitval: {msg: "done"}, stack: [{"subject_id" => vm_host_id}])
      expect { nx.wait_wave }.to hop("advance_wave")
      expect(st.reload.stack[0]["completed"]).to eq [vm_host_id]
    end
  end

  describe "#advance_wave" do
    it "advances within the gh_runner phase and schedules the next wave with the new wait_days" do
      expect { nx.advance_wave }.to hop("run_wave")
      frame = st.reload.stack[0]
      expect(frame["wave_index"]).to eq 1
      expect(frame["phase"]).to eq "gh_runner"
      expect(frame["next_wave_time"]).to be_within(5).of(Time.now.to_i + 3 * 86400)
    end

    it "transitions from the last gh_runner wave into the non_gh_runner phase" do
      refresh_frame(nx, new_values: {"wave_index" => described_class::GH_RUNNER_WAVES.size - 1})
      expect { nx.advance_wave }.to hop("run_wave")
      frame = st.reload.stack[0]
      expect(frame["phase"]).to eq "non_gh_runner"
      expect(frame["wave_index"]).to eq 0
      expect(frame["next_wave_time"]).to be_within(5).of(Time.now.to_i + 3 * 86400)
    end

    it "hops to done after the final non_gh_runner wave" do
      refresh_frame(nx, new_values: {
        "phase" => "non_gh_runner",
        "wave_index" => described_class::NON_GH_RUNNER_WAVES.size - 1,
      })
      expect { nx.advance_wave }.to hop("done")
    end
  end

  describe "#done" do
    it "naps forever by default" do
      expect { nx.done }.to nap(60 * 60 * 24 * 365)
    end

    it "exits when destroy semaphore is set" do
      nx.incr_destroy
      expect { nx.done }.to exit("msg" => "rollout completed")
    end
  end
end
