# frozen_string_literal: true

# Metrics of GitHub runner scheduling for the scheduler dashboard, as
# specified in demo/scheduler-dashboard/METRICS.md of the dashboard branch.
module SchedulerMetrics
  COUNTERS = %w[requests_received_total allocated_total started_total completed_total scheduling_checks_total order_inversions_total].freeze
  AGE_BUCKETS = [10, 30, 60, 120, 300, 600, 1800, 3600, nil].freeze
  VCPU_SIZES = [2, 4, 8, 16, 30].freeze
  LATENCY_WINDOW_SECONDS = 60
  ADMISSION_LABELS = %w[start wait_concurrency_limit apply_custom_label_quota].freeze
  FINISHED_LABELS = %w[destroy wait_vm_destroy].freeze

  ALERTS = [
    {id: "no_capacity_page", label: "NoCapacity page",
     metric: "stage_oldest_seconds.waiting_capacity", threshold: 3600, severity: "page",
     source: "prog/vm/metal/nexus.rb#start"},
    {id: "boot_deadline_page", label: "Boot deadline page",
     metric: "stage_oldest_seconds.booting", threshold: 600, severity: "page",
     source: "register_deadline(\"wait\", 10 * 60)"},
    {id: "admission_gate", label: "Admission gate",
     metric: "fleet.utilization", threshold: 0.8, severity: "monitor",
     source: "GithubRunnerNexus#wait_concurrency_limit"},
    {id: "idle_recycle", label: "Idle runner recycled",
     metric: "stage_oldest_seconds.idle", threshold: 310, severity: "monitor",
     source: "GithubRunnerNexus#wait"},
  ].freeze

  # Counters live in the database, as both web and respirate processes
  # increment them. They are incremented over a connection of their own, in
  # autocommit, as a counter row locked until the end of a strand's
  # transaction would serialize all strands incrementing it. Sequel connects
  # lazily, so each forked process gets its own connection.
  COUNTER_DB = Sequel.connect(Config.clover_database_url, max_connections: 1, test: false)

  def self.increment(name)
    COUNTER_DB[:scheduler_metric_counter]
      .insert_conflict(target: :name, update: {value: Sequel[:scheduler_metric_counter][:value] + 1})
      .insert(name:, value: 1)
  end

  # Called once a runner's VM has its host capacity reserved.
  def self.record_allocation(runner)
    increment("allocated_total")

    label_data = Github.runner_labels.fetch(runner.label)
    same_or_smaller = Github.runner_labels.select { |_, v| v["arch"] == label_data["arch"] && v["vcpus"] <= label_data["vcpus"] }.keys
    older_waiting = waiting_runners_dataset
      .where(Sequel[:github_runner][:label] => same_or_smaller)
      .where { Sequel[:github_runner][:created_at] < runner.created_at }
      .exclude(Sequel[:github_runner][:id] => runner.id)
    increment("order_inversions_total") unless older_waiting.empty?
  end

  def self.live_runners_dataset
    DB[:github_runner]
      .join(:strand, id: Sequel[:github_runner][:id])
      .left_join(:vm, id: Sequel[:github_runner][:vm_id])
      .exclude(Sequel[:strand][:label] => FINISHED_LABELS)
  end

  def self.waiting_runners_dataset
    live_runners_dataset.where(Sequel.|({Sequel[:strand][:label] => ADMISSION_LABELS + ["allocate_vm"]}, {Sequel[:vm][:allocated_at] => nil}))
  end

  def self.percentile(sorted, p)
    sorted.empty? ? 0 : sorted[((sorted.size - 1) * p).round].round(3)
  end

  def self.snapshot
    now = Time.now
    stages = {"waiting_admission" => 0, "waiting_capacity" => 0, "booting" => 0, "idle" => 0, "running" => 0}
    stage_oldest = {"waiting_admission" => 0, "waiting_capacity" => 0, "booting" => 0, "idle" => 0}
    waiting_ages = []
    by_vcpus = VCPU_SIZES.to_h { [it, {vcpus: it, waiting: 0, oldest_seconds: 0}] }

    live_runners_dataset.select(
      Sequel[:github_runner][:label], Sequel[:github_runner][:created_at], Sequel[:github_runner][:ready_at],
      Sequel[:github_runner][:workflow_job], Sequel[:strand][:label].as(:strand_label),
      Sequel[:vm][:created_at].as(:vm_created_at), Sequel[:vm][:allocated_at].as(:vm_allocated_at),
    ).each do |r|
      stage, entered_at = if ADMISSION_LABELS.include?(r[:strand_label])
        ["waiting_admission", r[:created_at]]
      elsif r[:strand_label] == "allocate_vm" || r[:vm_allocated_at].nil?
        ["waiting_capacity", r[:vm_created_at] || r[:created_at]]
      elsif r[:ready_at].nil?
        ["booting", r[:vm_allocated_at]]
      elsif r[:workflow_job]&.dig("status") == "in_progress"
        ["running", nil]
      else
        ["idle", r[:ready_at]]
      end

      stages[stage] += 1
      stage_oldest[stage] = [stage_oldest[stage], (now - entered_at).round(3)].max if entered_at
      next unless stage.start_with?("waiting")

      age = now - r[:created_at]
      waiting_ages << age
      if (size = by_vcpus[Github.runner_labels.dig(r[:label], "vcpus")])
        size[:waiting] += 1
        size[:oldest_seconds] = [size[:oldest_seconds], age.round(3)].max
      end
    end

    waiting_ages.sort!
    histogram = Array.new(AGE_BUCKETS.size, 0)
    waiting_ages.each { |age| histogram[AGE_BUCKETS.index { it.nil? || age <= it }] += 1 }

    latencies = DB[:github_runner]
      .join(:vm, id: :vm_id)
      .where { Sequel[:vm][:allocated_at] > now - LATENCY_WINDOW_SECONDS }
      .select_map(Sequel.extract(:epoch, Sequel[:vm][:allocated_at] - Sequel[:github_runner][:created_at]))
      .map(&:to_f).sort

    vcpus_total, vcpus_used = VmHost.where(allocation_state: "accepting", location_id: Location::GITHUB_RUNNERS_ID)
      .where { total_cores > 0 }
      .get { [sum(:total_cpus).as(:total), sum(used_cores * total_cpus / total_cores).as(:used)] }

    counters = COUNTERS.to_h { [it, 0] }.merge!(DB[:scheduler_metric_counter].to_hash(:name, :value).slice(*COUNTERS))

    {
      schema_version: 2,
      scheduler: Config.scheduler_metrics_name,
      display_name: Config.scheduler_metrics_display_name,
      generated_at: now.utc.iso8601(3),
      stages:,
      stage_oldest_seconds: stage_oldest,
      waiting: {
        count: waiting_ages.size,
        oldest_seconds: waiting_ages.last&.round(3) || 0,
        p50_seconds: percentile(waiting_ages, 0.5),
        p95_seconds: percentile(waiting_ages, 0.95),
        age_histogram: {le: AGE_BUCKETS, counts: histogram},
      },
      by_vcpus: by_vcpus.values,
      latency: {
        window_seconds: LATENCY_WINDOW_SECONDS,
        queue_to_allocated: {
          count: latencies.size,
          p50_seconds: percentile(latencies, 0.5),
          p95_seconds: percentile(latencies, 0.95),
          p99_seconds: percentile(latencies, 0.99),
        },
      },
      counters:,
      fleet: {vcpus_total: vcpus_total.to_i, vcpus_used: vcpus_used.to_i},
      alerts: ALERTS,
    }
  end
end
