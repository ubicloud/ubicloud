# frozen_string_literal: true

class Prog::RolloutVhostBlockBackend < Prog::Base
  semaphore :pause, :destroy

  # Each wave is {wait_days:, target_pct:}. wait_days is the delay before
  # starting the wave (after the previous wave finishes). target_pct is the
  # cumulative fraction of accepting hosts that should have the version
  # installed once this wave finishes.
  GH_RUNNER_WAVES = [
    {wait_days: 0, target_pct: 10},
    {wait_days: 3, target_pct: 40},
    {wait_days: 2, target_pct: 70},
    {wait_days: 2, target_pct: 100},
  ].freeze

  NON_GH_RUNNER_WAVES = [
    {wait_days: 3, target_pct: 20},
    {wait_days: 1, target_pct: 40},
    {wait_days: 1, target_pct: 60},
    {wait_days: 1, target_pct: 80},
    {wait_days: 1, target_pct: 100},
  ].freeze

  PHASES = %w[gh_runner non_gh_runner].freeze

  ARCHES = %w[x64 arm64].freeze

  # Versions that the rollout can target: ones with a known SHA on every
  # arch we need to canary on, newest first.
  def self.supported_versions
    VhostBlockBackend::SHA256_BY_VERSION_AND_ARCH.keys
      .group_by(&:first)
      .select { |_, pairs| pairs.map(&:last).to_set.superset?(ARCHES.to_set) }
      .keys
      .sort_by { Gem::Version.new(it.delete_prefix("v")) }
      .reverse
  end

  def self.assemble(version:)
    fail "Unsupported version: #{version}" unless supported_versions.include?(version)

    Strand.create(
      prog: "RolloutVhostBlockBackend",
      label: "start",
      stack: [{
        "version" => version,
        "phase" => "gh_runner",
        "wave_index" => 0,
        "next_wave_time" => Time.now.to_i,
        "completed" => [],
      }],
    )
  end

  def before_run
    when_pause_set? do
      nap 60 * 60
    end
    super
  end

  label def start
    hop_run_wave
  end

  label def run_wave
    nap_until(frame["next_wave_time"])

    pending = select_hosts(frame["phase"], current_wave.fetch(:target_pct))
      .reject { already_installed?(it) }
    pending.each { install_vbb(it) }
    hop_wait_wave
  end

  label def wait_wave
    reaper = lambda do |child|
      update_stack("completed" => frame.fetch("completed") << child.stack.first["subject_id"])
    end
    reap(:advance_wave, reaper:)
  end

  label def advance_wave
    next_index = frame["wave_index"] + 1
    if phase_waves(frame["phase"])[next_index]
      update_stack(
        "wave_index" => next_index,
        "next_wave_time" => Time.now.to_i + phase_waves(frame["phase"])[next_index][:wait_days] * 86400,
      )
      hop_run_wave
    elsif frame["phase"] == "gh_runner"
      update_stack(
        "phase" => "non_gh_runner",
        "wave_index" => 0,
        "next_wave_time" => Time.now.to_i + NON_GH_RUNNER_WAVES.first[:wait_days] * 86400,
      )
      hop_run_wave
    else
      hop_done
    end
  end

  label def done
    when_destroy_set? do
      pop "rollout completed"
    end
    nap(60 * 60 * 24 * 365)
  end

  def phase_waves(phase)
    (phase == "gh_runner") ? GH_RUNNER_WAVES : NON_GH_RUNNER_WAVES
  end

  def current_wave
    phase_waves(frame["phase"]).fetch(frame["wave_index"])
  end

  def select_hosts(phase, target_pct)
    base = VmHost
      .where(allocation_state: "accepting")
      .order(:created_at, :id)

    if phase == "gh_runner"
      base = base.where(location_id: Location::GITHUB_RUNNERS_ID)
      ARCHES.flat_map do |arch|
        ids = base.where(arch:).select_map(:id)
        ids.first(target_count(ids.size, target_pct))
      end
    else
      base = base.exclude(location_id: Location::GITHUB_RUNNERS_ID)
      ids = base.select_map(:id)
      ids.first(target_count(ids.size, target_pct))
    end
  end

  def target_count(total, target_pct)
    (total * target_pct / 100.0).ceil
  end

  def already_installed?(vm_host_id)
    VhostBlockBackend.where(vm_host_id:, version_code:).any?
  end

  def version_code
    @version_code ||= VhostBlockBackend.new(version: frame["version"]).version_code
  end

  def install_vbb(vm_host_id)
    bud Prog::Storage::SetupVhostBlockBackend, {
      "subject_id" => vm_host_id,
      "version" => frame["version"],
      "allocation_weight" => 0,
    }
  end

  def nap_until(time_int)
    time_left = time_int - Time.now.to_i
    nap(time_left) if time_left > 0
  end
end
