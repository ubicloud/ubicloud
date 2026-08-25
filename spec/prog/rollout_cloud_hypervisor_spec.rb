# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutCloudHypervisor do
  subject(:nx) { described_class.new(st) }

  let(:vm_host1) { create_vm_host(os_version: "ubuntu-24.04", created_at: Time.utc(2024, 1, 1)) }
  let(:vm_host2) { create_vm_host(os_version: "ubuntu-24.04", created_at: Time.utc(2024, 1, 2)) }
  let(:vm_host3) { create_vm_host(os_version: "ubuntu-24.04", created_at: Time.utc(2024, 1, 3)) }
  let(:st) {
    [vm_host1, vm_host2, vm_host3]
    described_class.assemble(concurrency: 2, version: "53.0", min_os_version: "ubuntu-24.04")
  }

  def set_lists(todo: nil, stages: nil, in_progress: nil, completed: nil, failures: nil)
    frame = st.stack.first
    frame["todo"] = todo if todo
    frame["stages"] = stages if stages
    frame["in_progress"] = in_progress if in_progress
    frame["completed"] = completed if completed
    frame["failures"] = failures if failures
    st.modified!(:stack)
    st.save_changes
  end

  def create_child(vm_host, exitval: nil, lease: nil, label: "download")
    Strand.create(
      parent_id: st.id,
      prog: "DownloadCloudHypervisor",
      label:,
      stack: [{"subject_id" => vm_host.id, "version" => "53.0"}],
      **({exitval: Sequel.pg_jsonb_wrap(exitval)} if exitval),
      **({lease:} if lease),
    )
  end

  def reload_frame
    st.reload.stack.first
  end

  describe ".assemble" do
    it "creates strand with hosts grouped into location stages in rollout order" do
      github_runner_host = create_vm_host(os_version: "ubuntu-24.04", location_id: Location::GITHUB_RUNNERS_ID)
      hel1_host = create_vm_host(os_version: "ubuntu-24.04", location_id: Location::HETZNER_HEL1_ID)
      wdc02_host = create_vm_host(os_version: "ubuntu-24.04", location_id: Location::LEASEWEB_WDC02_ID)

      expect(st.label).to eq("wait")
      expect(st.prog).to eq("RolloutCloudHypervisor")

      frame = st.stack.first
      expect(frame["concurrency"]).to eq(2)
      expect(frame["version"]).to eq("53.0")
      expect(frame["arch"]).to eq("x64")
      expect(frame["pause_stages"]).to be false

      expect(frame["todo"]).to eq([github_runner_host.id])
      expect(frame["stages"]).to eq([[vm_host1.id, vm_host2.id, vm_host3.id], [hel1_host.id], [wdc02_host.id]])
      expect(frame["in_progress"]).to eq([])
      expect(frame["completed"]).to eq([])
      expect(frame["failures"]).to eq({})
    end

    it "sorts hosts by created_at within a stage and drops empty stages" do
      expect(st.stack.first["todo"]).to eq([vm_host1.id, vm_host2.id, vm_host3.id])
      expect(st.stack.first["stages"]).to eq([])
    end

    it "fails for invalid arch" do
      expect {
        described_class.assemble(concurrency: 2, version: "53.0", arch: "s390x")
      }.to raise_error(RuntimeError, "Invalid arch: s390x")
    end

    it "only includes hosts with the given arch" do
      arm64_host = create_vm_host(arch: "arm64", os_version: "ubuntu-24.04", location_id: Location::GITHUB_RUNNERS_ID)
      vm_host1

      strand = described_class.assemble(concurrency: 2, version: "53.0", arch: "arm64")

      expect(strand.stack.first["todo"]).to eq([arm64_host.id])
      expect(strand.stack.first["stages"]).to eq([])
    end

    it "only includes hosts with os_version >= min_os_version" do
      create_vm_host(os_version: "ubuntu-22.04", location_id: Location::GITHUB_RUNNERS_ID)
      newer_host = create_vm_host(os_version: "ubuntu-26.04", location_id: Location::HETZNER_HEL1_ID)

      [vm_host1, vm_host2, vm_host3]
      strand = described_class.assemble(concurrency: 2, version: "53.0", min_os_version: "ubuntu-24.04")

      expect(strand.stack.first["todo"]).to eq([vm_host1.id, vm_host2.id, vm_host3.id])
      expect(strand.stack.first["stages"]).to eq([[newer_host.id]])
    end

    it "includes hosts regardless of os_version when min_os_version is not given" do
      host_without_os_version = create_vm_host(location_id: Location::GITHUB_RUNNERS_ID)

      strand = described_class.assemble(concurrency: 2, version: "53.0")

      expect(strand.stack.first["todo"]).to eq([host_without_os_version.id])
    end

    it "excludes explicitly given host ids" do
      vm_host1

      strand = described_class.assemble(
        concurrency: 2, version: "53.0",
        exclude_vm_host_ids: [vm_host2.id, vm_host3.id],
      )

      expect(strand.stack.first["todo"]).to eq([vm_host1.id])
    end
  end

  describe "#wait" do
    it "naps when pause semaphore is set" do
      nx.incr_pause
      expect { nx.wait }.to nap(60 * 60)
    end

    it "hops to cancel when cancel semaphore is set" do
      nx.incr_cancel
      expect { nx.wait }.to hop("cancel")
    end

    it "reaps completed children and moves them to completed" do
      set_lists(todo: [vm_host3.id], in_progress: [vm_host1.id, vm_host2.id])
      create_child(vm_host1, exitval: {"msg" => "cloud hypervisor downloaded"}, lease: Time.now - 1)
      create_child(vm_host2, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)

      frame = reload_frame
      expect(frame["completed"]).to eq([vm_host1.id])
      expect(frame["in_progress"]).not_to include(vm_host1.id)
    end

    it "moves failed host back to todo with incremented failure count" do
      set_lists(todo: [vm_host3.id], in_progress: [vm_host1.id, vm_host2.id])
      create_child(vm_host1, exitval: {"msg" => "operation cancelled"}, lease: Time.now - 1)
      create_child(vm_host2, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)

      frame = reload_frame
      expect(frame["in_progress"]).not_to include(vm_host1.id)
      expect(frame["todo"]).to eq([vm_host1.id])
      expect(frame["failures"]).to eq({vm_host1.id => 1})
    end

    it "re-buds failed host on next cycle" do
      set_lists(todo: [vm_host1.id], in_progress: [], completed: [vm_host2.id, vm_host3.id], failures: {vm_host1.id => 2})

      expect { nx.wait }.to nap(15)

      frame = reload_frame
      expect(frame["todo"]).to eq([])
      expect(frame["in_progress"]).to eq([vm_host1.id])

      child = st.children_dataset.first
      expect(child.prog).to eq("DownloadCloudHypervisor")
      expect(child.stack.first["subject_id"]).to eq(vm_host1.id)
      expect(child.stack.first["version"]).to eq("53.0")
    end

    it "fills concurrency slots from todo in order" do
      expect { nx.wait }.to nap(15)

      frame = reload_frame
      expect(frame["todo"]).to eq([vm_host3.id])
      expect(frame["in_progress"]).to contain_exactly(vm_host1.id, vm_host2.id)
      expect(frame["completed"]).to eq([])

      children = st.children_dataset.all
      expect(children.length).to eq(2)
      subject_ids = children.map { it.stack.first["subject_id"] }
      expect(subject_ids).to contain_exactly(vm_host1.id, vm_host2.id)
    end

    it "respects concurrency limit" do
      set_lists(todo: [vm_host3.id], in_progress: [vm_host1.id, vm_host2.id])
      create_child(vm_host1)
      create_child(vm_host2)

      expect { nx.wait }.to nap(15)

      expect(reload_frame["todo"]).to eq([vm_host3.id])
      expect(st.children_dataset.count).to eq(2)
    end

    it "pops when all stages are done and all children are reaped" do
      set_lists(todo: [], stages: [], in_progress: [], completed: [vm_host1.id, vm_host2.id, vm_host3.id])

      expect { nx.wait }.to exit({"msg" => "rollout completed"})
    end

    it "hops to next_stage when the current stage is done" do
      set_lists(todo: [], stages: [[vm_host3.id]], in_progress: [], completed: [vm_host1.id, vm_host2.id])

      expect { nx.wait }.to hop("next_stage")

      expect(Semaphore.where(strand_id: st.id, name: "pause")).to be_empty
    end

    it "increments pause before hopping to next_stage when pause_stages is set" do
      st.stack.first["pause_stages"] = true
      set_lists(todo: [], stages: [[vm_host3.id]], in_progress: [], completed: [vm_host1.id, vm_host2.id])

      expect { nx.wait }.to hop("next_stage")

      expect(Semaphore.where(strand_id: st.id, name: "pause").count).to eq(1)
    end

    it "naps when children are still active" do
      set_lists(todo: [], in_progress: [vm_host1.id])
      create_child(vm_host1, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)
    end

    it "does not start the next stage while children are still active" do
      set_lists(todo: [], stages: [[vm_host3.id]], in_progress: [vm_host1.id], completed: [vm_host2.id])
      create_child(vm_host1, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)

      expect(reload_frame["stages"]).to eq([[vm_host3.id]])
    end
  end

  describe "#next_stage" do
    it "moves the next stage into todo and hops to wait" do
      set_lists(todo: [], stages: [[vm_host3.id]], in_progress: [], completed: [vm_host1.id, vm_host2.id])

      expect { nx.next_stage }.to hop("wait")

      frame = st.stack.first
      expect(frame["todo"]).to eq([vm_host3.id])
      expect(frame["stages"]).to eq([])
    end
  end

  describe "#cancel" do
    it "waits for active children to finish on their own, without signalling them" do
      child = create_child(vm_host1, lease: Time.now + 100)

      expect { nx.cancel }.to nap

      expect(Semaphore.where(strand_id: child.id).count).to eq(0)
    end

    it "pops once all children are reaped" do
      expect { nx.cancel }.to exit({"msg" => "rollout cancelled"})
    end
  end
end
