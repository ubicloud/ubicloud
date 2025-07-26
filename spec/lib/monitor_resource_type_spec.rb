# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MonitorResourceType do
  after do
    @mrt&.wait_cleanup!(1)
  end

  describe ".create" do
    it "creates an instance with appropriate settings" do
      c = Class.new
      @mrt = mrt = described_class.create(c, :foo, 4, [[:foo], [:bar]])
      expect(mrt.wrapper_class.equal?(c)).to be true
      expect(mrt.resources).to eq({})
      expect(mrt.types).to eq [[:foo], [:bar]]
      expect(mrt.submit_queue).to be_a SizedQueue
      expect(mrt.submit_queue.max).to eq 5
      expect(mrt.finish_queue).to be_a Queue
      expect(mrt.run_queue).to eq []
      expect(mrt.threads.size).to eq 2
      expect(mrt.threads.all?(Thread)).to be true
      expect(mrt.stuck_pulse_info).to eq :foo
    end

    it "clamps pool size, and bases queue size on pool size and object count" do
      @mrt = mrt = described_class.create(Object, :foo, 2, [[]])
      expect(mrt.submit_queue.max).to eq 1
      expect(mrt.threads.size).to eq 1
    end
  end

  describe "thread pool" do
    it "processes jobs on submit queue" do
      started_at = nil
      @mrt = mrt = described_class.create(Object, :foo, 2, [[]]) do
        started_at = it.monitor_job_started_at
      end

      mr = MonitorableResource.new(nil)
      expect(mr).to receive(:open_resource_session)
      mrt.submit_queue.push(mr)

      expect(mrt.finish_queue.pop(timeout: 1)).to eq mr
      expect(started_at).to be_within(1).of(Time.now)
      expect(mr.monitor_job_started_at).to be_nil
      expect(mr.monitor_job_finished_at).to be_within(1).of(Time.now)
    end
  end

  describe "#check_stuck_pulses" do
    before do
      @mrt = described_class.create(Object, [5, "stuck", :stuck], 2, [[]])
    end

    it "emits for active jobs running longer than the stuck pulse timeout" do
      mr = MonitorableResource.new(VmHost.new_with_id)
      mr.monitor_job_started_at = Time.now - 10
      @mrt.resources[1] = mr
      expect(Clog).to receive(:emit).with("stuck").and_call_original
      @mrt.check_stuck_pulses
    end

    it "does not emit for active jobs not running longer than the stuck pulse timeout" do
      mr = MonitorableResource.new(nil)
      mr.monitor_job_started_at = Time.now
      @mrt.resources[1] = mr
      expect(Clog).not_to receive(:emit)
      @mrt.check_stuck_pulses
    end

    it "does not emit for non-active jobs" do
      @mrt.resources[1] = MonitorableResource.new(nil)
      expect(Clog).not_to receive(:emit)
      @mrt.check_stuck_pulses
    end
  end

  describe "#scan" do
    entire_range = "00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff"

    before do
      @mrt = described_class.create(MonitorableResource, [5, "stuck", :stuck], 2, [VmHost])
    end

    it "adds resources picked up by scan to resources" do
      vm_host = create_vm_host
      expect(@mrt.resources).to eq({})
      @mrt.scan(entire_range)
      expect(@mrt.resources.keys).to eq [vm_host.id]
      expect(@mrt.resources.values.map(&:resource)).to eq [vm_host]
    end

    it "removes entries from resources if they were not picked up" do
      @mrt.resources[1] = nil
      @mrt.scan(entire_range)
      expect(@mrt.resources).to eq({})
    end

    it "returns new resources that were not previously in resources" do
      vm_host = create_vm_host
      @mrt.resources[1] = nil
      expect(@mrt.scan(entire_range).map(&:resource)).to eq [vm_host]
      expect(@mrt.scan(entire_range)).to eq []
    end

    it "respects given id_range when scanning for objects" do
      vm_host = create_vm_host
      @mrt.scan("00000000-0000-0000-0000-000000000000"...vm_host.id)
      expect(@mrt.resources.keys).to eq []
      @mrt.scan(vm_host.id.."ffffffff-ffff-ffff-ffff-ffffffffffff")
      expect(@mrt.resources.keys).to eq [vm_host.id]
      @mrt.scan("00000000-0000-0000-0000-000000000000"..vm_host.id)
      expect(@mrt.resources.keys).to eq [vm_host.id]
    end
  end

  describe "#enqueue" do
    let(:mr) { MonitorableResource.new(VmHost.new) }

    before do
      @mrt = described_class.create(nil, nil, 2, [])
    end

    it "moves jobs from finish queue to run queue" do
      mr.monitor_job_finished_at = Time.now
      @mrt.finish_queue.push(mr)
      expect(@mrt.run_queue).to eq []
      @mrt.enqueue(Time.now - 5)
      expect(@mrt.run_queue).to eq [mr]
      expect(@mrt.finish_queue.pop(timeout: 0)).to be_nil
    end

    it "does not submit jobs if run queue is empty" do
      @mrt.submit_queue.close
      @mrt.enqueue(Time.now)
      expect(@mrt.run_queue).to eq []
    end

    it "does not submit jobs if all jobs in run_queue are not yet ready to be run again" do
      @mrt.submit_queue.close
      mr.monitor_job_finished_at = Time.now
      @mrt.run_queue.push(mr)
      @mrt.enqueue(Time.now - 5)
      expect(@mrt.run_queue).to eq [mr]
    end

    it "only submits jobs in run queue that are ready to be run again" do
      submit_queue = @mrt.submit_queue
      @mrt.submit_queue = Queue.new
      mr.monitor_job_finished_at = Time.now
      @mrt.run_queue.push(mr)
      @mrt.resources[nil] = mr
      @mrt.enqueue(Time.now + 5)
      expect(@mrt.run_queue).to eq []
      expect(@mrt.submit_queue.pop(timeout: 0)).to eq mr
    ensure
      @mrt.submit_queue = submit_queue
    end

    it "does not submit jobs in run queue if resource is no longer monitored" do
      @mrt.submit_queue.close
      mr.monitor_job_finished_at = Time.now
      @mrt.run_queue.push(mr)
      @mrt.enqueue(Time.now + 5)
      expect(@mrt.run_queue).to eq []
    end

    it "returns nil if no jobs are in the run queue" do
      expect(@mrt.enqueue(Time.now)).to be_nil
    end

    it "returns nil if all jobs in the run queue were submitted or dropped" do
      mr.monitor_job_finished_at = Time.now
      @mrt.run_queue.push(mr)
      expect(@mrt.enqueue(Time.now + 5)).to be_nil
    end

    it "returns the last finish time of the first remaining entry in the run queue" do
      t = mr.monitor_job_finished_at = Time.now
      @mrt.run_queue.push(mr)
      expect(@mrt.enqueue(Time.now - 5)).to eq t
    end
  end
end
