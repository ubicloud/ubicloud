# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutBootImage do
  subject(:nx) { described_class.new(st) }

  let(:vm_host1) { create_vm_host(created_at: Time.utc(2024, 1, 1)) }
  let(:vm_host2) { create_vm_host(created_at: Time.utc(2024, 1, 2)) }
  let(:vm_host3) { create_vm_host(created_at: Time.utc(2024, 1, 3)) }
  let(:st) {
    [vm_host1, vm_host2, vm_host3]
    described_class.assemble(
      concurrency: 2,
      image_name: "github-ubuntu-2404",
      version: "20260312.1.0",
    )
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
    it "creates strand with hosts grouped into location stages in rollout order" do
      github_runner_host = create_vm_host(location_id: Location::GITHUB_RUNNERS_ID)
      hel1_host = create_vm_host(location_id: Location::HETZNER_HEL1_ID)
      wdc02_host = create_vm_host(location_id: Location::LEASEWEB_WDC02_ID)

      expect(st.label).to eq("wait")
      expect(st.prog).to eq("RolloutBootImage")

      frame = st.stack.first
      expect(frame["concurrency"]).to eq(2)
      expect(frame["image_name"]).to eq("github-ubuntu-2404")
      expect(frame["version"]).to eq("20260312.1.0")
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
        described_class.assemble(concurrency: 2, image_name: "github-ubuntu-2404", version: "20260312.1.0", arch: "s390x")
      }.to raise_error(RuntimeError, "Invalid arch: s390x")
    end

    it "only includes hosts with the given arch" do
      arm64_host = create_vm_host(arch: "arm64", location_id: Location::GITHUB_RUNNERS_ID)
      vm_host1

      strand = described_class.assemble(
        concurrency: 2, image_name: "github-ubuntu-2404", version: "20260312.1.0", arch: "arm64",
      )

      expect(strand.stack.first["todo"]).to eq([arm64_host.id])
      expect(strand.stack.first["stages"]).to eq([])
    end

    it "excludes hosts running minio servers by default, but includes them if requested" do
      mc = MinioCluster.create(
        location_id: Location::HETZNER_FSN1_ID,
        name: "minio-cluster-name",
        admin_user: "minio-admin",
        admin_password: "dummy-password",
        root_cert_1: "dummy-root-cert-1",
        root_cert_2: "dummy-root-cert-2",
        project_id: Project.create(name: "test").id,
      )
      mp = MinioPool.create(
        cluster_id: mc.id,
        start_index: 0,
        server_count: 1,
        drive_count: 1,
        storage_size_gib: 100,
        vm_size: "standard-2",
      )
      minio_host = create_vm_host(created_at: Time.utc(2024, 1, 4))
      MinioServer.create(
        minio_pool_id: mp.id,
        vm_id: create_vm(vm_host_id: minio_host.id).id,
        index: 0,
      )

      expect(st.stack.first["todo"]).to eq([vm_host1.id, vm_host2.id, vm_host3.id])

      strand = described_class.assemble(
        concurrency: 2, image_name: "github-ubuntu-2404", version: "20260312.1.0", exclude_minio_hosts: false,
      )
      expect(strand.stack.first["todo"]).to eq([vm_host1.id, vm_host2.id, vm_host3.id, minio_host.id])
    end

    it "excludes explicitly given host ids" do
      vm_host1

      strand = described_class.assemble(
        concurrency: 2, image_name: "github-ubuntu-2404", version: "20260312.1.0",
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
    it "removes downloaded images from started hosts and pops, leaving pending stages untouched" do
      pending_host = create_vm_host(location_id: Location::HETZNER_HEL1_ID)
      set_lists(
        todo: [vm_host3.id],
        stages: [[pending_host.id]],
        in_progress: [],
        completed: [vm_host1.id, vm_host2.id],
      )
      BootImage.create(vm_host_id: vm_host1.id, name: "github-ubuntu-2404", version: "20260312.1.0", size_gib: 3, activated_at: Time.now)
      BootImage.create(vm_host_id: vm_host2.id, name: "github-ubuntu-2404", version: "20260312.1.0", size_gib: 3, activated_at: Time.now)
      BootImage.create(vm_host_id: pending_host.id, name: "github-ubuntu-2404", version: "20260312.1.0", size_gib: 3, activated_at: Time.now)

      expect { nx.remove_downloaded_images }.to exit({"msg" => "rollout rolled back"})

      expect(Strand.where(prog: "RemoveBootImage").count).to eq(2)
    end
  end
end
