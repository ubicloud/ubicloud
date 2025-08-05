# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MonitorRunner do
  stuck_info = [10, "stuck", :stuck].freeze

  let(:monitor_runner) do
    described_class.new(monitor_resources:, metric_export_resources:, repartitioner:, **monitor_runner_args)
  end
  let(:monitor_resources) { MonitorResourceType.create(MonitorableResource, stuck_info, 2, [VmHost]) {} }
  let(:metric_export_resources) { MonitorResourceType.create(MetricsTargetResource, stuck_info, 2, [VmHost]) {} }
  let(:repartitioner) { MonitorRepartitioner.new(2) }
  let(:monitor_runner_args) do
    {
      scan_every: 0.01,
      report_every: 0.01,
      enqueue_every: 0.01,
      check_stuck_pulses_every: 0.01
    }
  end

  def vm_host_with_id(id)
    Sshable.create_with_id(id)
    VmHost.create_with_id(id, location_id: Location::HETZNER_FSN1_ID, allocation_state: "accepting", arch: "x64", family: "standard", total_cores: 48, used_cores: 2)
  end

  after do
    monitor_runner.wait_cleanup!(1)
  end

  describe "#scan" do
    it "scans both resource types and pushes only new resources in partition to respective queues" do
      vm1 = vm_host_with_id("90000000-0000-0000-0000-000000000000")
      vm2 = vm_host_with_id("a0000000-0000-0000-0000-000000000000")

      # Check that it doesn't pick up resources outside partition
      vm_host_with_id("10000000-0000-0000-0000-000000000000")

      msq = monitor_resources.submit_queue
      mesq = metric_export_resources.submit_queue
      q1 = monitor_resources.submit_queue = Queue.new
      q2 = metric_export_resources.submit_queue = Queue.new

      # Check that id doesn't pick up existing resources
      monitor_resources.resources[vm2.id] = true
      metric_export_resources.resources[vm2.id] = true

      monitor_runner.scan

      v = q1.pop(timeout: 1)
      expect(v).to be_a MonitorableResource
      expect(v.resource).to eq vm1

      v = q2.pop(timeout: 1)
      expect(v).to be_a MetricsTargetResource
      expect(v.resource).to eq vm1

      expect(q1.pop(timeout: 0)).to be_nil
      expect(q2.pop(timeout: 0)).to be_nil
    ensure
      monitor_resources.submit_queue = msq
      metric_export_resources.submit_queue = mesq
    end
  end

  describe "#emit_metrics" do
    it "emits metrics" do
      q = Queue.new
      expect(Clog).to receive(:emit).at_least(:once).and_wrap_original do |m, a, &b|
        if a == "monitor metrics"
          m.call(a, &b)
          q.push(b.call)
        end
      end

      monitor_runner.emit_metrics
      hash = q.pop(timeout: 1)
      expect(hash.keys).to eq [:monitor_metrics]
      hash = hash[:monitor_metrics]
      expect(hash.delete(:active_threads_count)).to be_a Integer
      expect(hash.delete(:monitor_idle_worker_threads)).to be <= 1
      expect(hash.delete(:metric_export_idle_worker_threads)).to be <= 1
      expect(hash).to eq({
        threads_waiting_for_db_connection: 0,
        total_monitor_resources: 0,
        total_metric_export_resources: 0,
        monitor_submit_queue_length: 0,
        metric_export_submit_queue_length: 0
      })

      monitor_resources.resources["a0000000-0000-0000-0000-000000000000"] = true
      metric_export_resources.resources["90000000-0000-0000-0000-000000000000"] = true
      metric_export_resources.resources["a0000000-0000-0000-0000-000000000000"] = true

      mr = MonitorableResource.new(nil)
      q2 = Queue.new
      expect(mr).to receive(:open_resource_session).twice do
        q2.pop(timeout: 1)
      end
      2.times { monitor_resources.submit_queue.push(mr) }

      monitor_runner.emit_metrics
      hash = q.pop(timeout: 1)
      expect(hash.keys).to eq [:monitor_metrics]
      hash = hash[:monitor_metrics]
      expect(hash.delete(:active_threads_count)).to be_a Integer
      expect(hash).to eq({
        threads_waiting_for_db_connection: 0,
        total_monitor_resources: 1,
        total_metric_export_resources: 2,
        monitor_submit_queue_length: 1,
        metric_export_submit_queue_length: 0,
        monitor_idle_worker_threads: 0,
        metric_export_idle_worker_threads: 1
      })
      2.times { q2.push nil }
    end
  end

  describe "#check_stuck_pulses" do
    it "emits for stuck pulses" do
      i = 0
      expect(Clog).to receive(:emit).at_least(:once) do |a|
        i += 1 if a == "stuck"
      end
      monitor_runner.check_stuck_pulses
      expect(i).to eq 0

      mr = MonitorableResource.new(VmHost.new_with_id)
      mr.monitor_job_started_at = Time.now - 5
      monitor_resources.resources[1] = mr
      metric_export_resources.resources[1] = mr
      monitor_runner.check_stuck_pulses
      expect(i).to eq 0

      mr.monitor_job_started_at = Time.now - 15
      monitor_runner.check_stuck_pulses
      expect(i).to eq 2
    end
  end

  describe "#enqueue" do
    before do
      monitor_runner_args[:enqueue_every] = 10
    end

    it "enqueues jobs for both resource types" do
      mr = MonitorableResource.new(VmHost.new_with_id)
      mr.monitor_job_finished_at = Time.now - 15
      monitor_resources.run_queue << mr

      mr = MetricsTargetResource.new(VmHost.new_with_id)
      mr.monitor_job_finished_at = Time.now - 15
      metric_export_resources.run_queue << mr

      expect(monitor_resources.run_queue.size).to eq 1
      expect(metric_export_resources.run_queue.size).to eq 1
      monitor_runner.enqueue
      expect(monitor_resources.run_queue.size).to eq 0
      expect(metric_export_resources.run_queue.size).to eq 0
    end

    it "returns enqueue_every if there are no jobs in either run queue" do
      expect(monitor_runner.enqueue).to eq 10
    end

    it "returns time to sleep based on next entry in run queue" do
      mr = MonitorableResource.new(VmHost.new_with_id)
      mr.monitor_job_finished_at = Time.now - 4
      monitor_resources.run_queue << mr
      expect(monitor_resources.run_queue.size).to eq 1
      expect(monitor_runner.enqueue).to be_within(1).of(6)

      mr = MetricsTargetResource.new(VmHost.new_with_id)
      mr.monitor_job_finished_at = Time.now - 8
      metric_export_resources.run_queue << mr
      expect(monitor_runner.enqueue).to be_within(1).of(2)
      expect(metric_export_resources.run_queue.size).to eq 1

      mr.monitor_job_finished_at = Time.now - 12
      expect(monitor_runner.enqueue).to be_within(1).of(6)
      expect(metric_export_resources.run_queue.size).to eq 0
    end
  end

  describe "#run" do
    before do
      i = 0
      monitor_runner_args[:enqueue_every] = 0
      monitor_runner.define_singleton_method(:enqueue) do
        shutdown! if i == 100
        i += 1
        super()
      end
    end

    it "runs scan/report/check_stuck_pulse/enqueue loop with no resources" do
      expect(monitor_runner.run).to be_nil
    end

    it "runs scan/report/check_stuck_pulse/enqueue loop with resources" do
      vm1 = vm_host_with_id("90000000-0000-0000-0000-000000000000")
      msq = monitor_resources.submit_queue
      mesq = metric_export_resources.submit_queue
      q1 = monitor_resources.submit_queue = Queue.new
      q2 = metric_export_resources.submit_queue = Queue.new

      monitor_runner.instance_variable_set(:@report_every, 0)
      monitor_runner.instance_variable_set(:@check_stuck_pulses_every, 0)
      monitor_runner.run
      expect(q1.pop(timeout: 0).resource).to eq vm1
      expect(q2.pop(timeout: 0).resource).to eq vm1
    ensure
      monitor_resources.submit_queue = msq
      metric_export_resources.submit_queue = mesq
    end

    it "handles ClosedQueueError before shutdown" do
      vm_host_with_id("90000000-0000-0000-0000-000000000000")
      monitor_resources.submit_queue.close
      expect(monitor_runner.run).to be_nil
    end

    it "handles shutting down after scanning" do
      monitor_runner.define_singleton_method(:scan) do
        super()
        shutdown!
      end
      expect(monitor_runner.run).to be_nil
    end

    it "handles shutting down before scanning when there are resources" do
      vm_host_with_id("90000000-0000-0000-0000-000000000000")
      monitor_runner.define_singleton_method(:scan) do
        shutdown!
        super()
      end
      expect(monitor_runner.run).to be_nil
    end

    it "thread prints and exits for other failures" do
      exited = false
      expect(ThreadPrinter).to receive(:run)
      expect(Kernel).to receive(:exit!).and_invoke(->(_) { exited = true })
      expect(Clog).to receive(:emit).with("Pulse checking or resource scanning has failed.").and_call_original
      monitor_runner.define_singleton_method(:scan) { raise }
      monitor_runner.run
      expect(exited).to be true
    end
  end
end
