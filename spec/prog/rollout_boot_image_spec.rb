# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutBootImage do
  subject(:nx) { described_class.new(st) }

  let(:vm_host1) { create_vm_host(created_at: Time.utc(2024, 1, 1)) }
  let(:vm_host2) { create_vm_host(created_at: Time.utc(2024, 1, 2)) }
  let(:vm_host3) { create_vm_host(created_at: Time.utc(2024, 1, 3)) }
  let(:st) {
    described_class.assemble(
      vm_hosts: [vm_host3, vm_host1, vm_host2],
      concurrency: 2,
      image_name: "github-ubuntu-2404",
      version: "20260312.1.0",
    )
  }

  def set_lists(todo: nil, in_progress: nil, completed: nil, failures: nil)
    frame = st.stack.first
    frame["todo"] = todo if todo
    frame["in_progress"] = in_progress if in_progress
    frame["completed"] = completed if completed
    frame["failures"] = failures if failures
    st.modified!(:stack)
    st.save_changes
  end

  def create_child(vm_host, exitval: nil, lease: nil, label: "download")
    Strand.create(
      parent_id: st.id,
      prog: "DownloadBootImage",
      label:,
      stack: [{"subject_id" => vm_host.id, "image_name" => "github-ubuntu-2404", "version" => "20260312.1.0"}],
      **({exitval: Sequel.pg_jsonb_wrap(exitval)} if exitval),
      **({lease:} if lease),
    )
  end

  def reload_frame
    st.reload.stack.first
  end

  describe ".assemble" do
    it "creates strand with hosts sorted by created_at in todo" do
      strand = described_class.assemble(
        vm_hosts: [vm_host3, vm_host1, vm_host2],
        concurrency: 2,
        image_name: "github-ubuntu-2404",
        version: "20260312.1.0",
      )

      expect(strand.label).to eq("wait")
      expect(strand.prog).to eq("RolloutBootImage")

      frame = strand.stack.first
      expect(frame["concurrency"]).to eq(2)
      expect(frame["image_name"]).to eq("github-ubuntu-2404")
      expect(frame["version"]).to eq("20260312.1.0")

      expect(frame["todo"]).to eq([vm_host1.id, vm_host2.id, vm_host3.id])
      expect(frame["in_progress"]).to eq([])
      expect(frame["completed"]).to eq([])
      expect(frame["failures"]).to eq({})
    end
  end

  describe "#wait" do
    it "hops to rollback when rollback semaphore is set" do
      nx.incr_rollback
      expect { nx.wait }.to hop("rollback")
    end

    it "reaps completed children and moves them to completed" do
      set_lists(todo: [vm_host3.id], in_progress: [vm_host1.id, vm_host2.id])
      create_child(vm_host1, exitval: {"msg" => "image downloaded"}, lease: Time.now - 1)
      create_child(vm_host2, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)

      frame = reload_frame
      expect(frame["completed"]).to eq([vm_host1.id])
      expect(frame["in_progress"]).not_to include(vm_host1.id)
    end

    it "marks host as completed when image already exists on host" do
      set_lists(todo: [vm_host3.id], in_progress: [vm_host1.id, vm_host2.id])
      create_child(vm_host1, exitval: {"msg" => "Image already exists on host"}, lease: Time.now - 1)
      create_child(vm_host2, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)

      expect(reload_frame["completed"]).to eq([vm_host1.id])
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
      expect(child.prog).to eq("DownloadBootImage")
      expect(child.stack.first["subject_id"]).to eq(vm_host1.id)
      expect(child.stack.first["exit_on_fail"]).to be true
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

    it "pops when todo is empty and all children are reaped" do
      set_lists(todo: [], in_progress: [], completed: [vm_host1.id, vm_host2.id, vm_host3.id])

      expect { nx.wait }.to exit({"msg" => "rollout completed"})
    end

    it "naps when children are still active" do
      set_lists(todo: [], in_progress: [vm_host1.id])
      create_child(vm_host1, lease: Time.now + 100)

      expect { nx.wait }.to nap(15)
    end
  end

  describe "#rollback" do
    it "signals cancel on active children and waits for them" do
      child = create_child(vm_host1, lease: Time.now + 100)

      expect { nx.rollback }.to nap

      expect(Semaphore.where(strand_id: child.id, name: "cancel").count).to eq(1)
    end

    it "hops to remove_downloaded_images when all children are reaped" do
      expect { nx.rollback }.to hop("remove_downloaded_images")
    end
  end

  describe "#remove_downloaded_images" do
    it "removes downloaded images from all hosts and pops" do
      set_lists(
        todo: [vm_host3.id],
        in_progress: [],
        completed: [vm_host1.id, vm_host2.id],
      )
      BootImage.create(vm_host_id: vm_host1.id, name: "github-ubuntu-2404", version: "20260312.1.0", size_gib: 3, activated_at: Time.now)
      BootImage.create(vm_host_id: vm_host2.id, name: "github-ubuntu-2404", version: "20260312.1.0", size_gib: 3, activated_at: Time.now)

      expect { nx.remove_downloaded_images }.to exit({"msg" => "rollout rolled back"})

      expect(Strand.where(prog: "RemoveBootImage").count).to eq(2)
    end
  end
end
