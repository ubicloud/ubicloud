# frozen_string_literal: true

class Prog::RolloutCloudHypervisor < Prog::Base
  semaphore :cancel, :pause
  frame_reader :concurrency, :version, :arch, :todo, :in_progress, :completed, :failures, :stages, :pause_stages

  STAGE_LOCATION_IDS = [
    Location::GITHUB_RUNNERS_ID,
    Location::HETZNER_FSN1_ID,
    Location::HETZNER_HEL1_ID,
    Location::LEASEWEB_WDC02_ID,
  ].freeze

  def self.assemble(version:, concurrency:, arch: "x64", min_os_version: nil, exclude_vm_host_ids: [], pause_stages: false)
    fail "Invalid arch: #{arch}" unless ["x64", "arm64"].include?(arch)

    ds = VmHost.where(arch:).exclude(id: exclude_vm_host_ids)
    ds = ds.where { Sequel[:vm_host][:os_version] >= min_os_version } if min_os_version

    stages = DB.ignore_duplicate_queries do
      STAGE_LOCATION_IDS.map { |location_id| ds.where(location_id:).order(:created_at, :id).select_map(:id) }
    end
    stages.reject!(&:empty?)
    todo = stages.shift || []

    Strand.create(
      prog: "RolloutCloudHypervisor",
      label: "wait",
      stack: [{
        "todo" => todo,
        "stages" => stages,
        "in_progress" => [],
        "completed" => [],
        "failures" => {},
        "concurrency" => concurrency,
        "version" => version,
        "arch" => arch,
        "pause_stages" => pause_stages,
      }],
    )
  end

  label def wait
    when_cancel_set? do
      hop_cancel
    end

    when_pause_set? do
      nap 60 * 60
    end

    reaper = lambda do |child|
      host_id = child.stack.first["subject_id"]
      in_progress.delete(host_id)
      case child.exitval["msg"]
      when "cloud hypervisor downloaded"
        completed.push(host_id)
      else
        failures[host_id] = (failures[host_id] || 0) + 1
        todo.push(host_id)
      end
    end

    reap(fallthrough: true, reaper:) do
      if todo.empty? && in_progress.empty?
        pop "rollout completed" if stages.empty?
        incr_pause if pause_stages
        hop_next_stage
      end
    end

    # Fill concurrency slots from the todo queue
    slots_to_fill = concurrency - strand.children_dataset.count
    while slots_to_fill > 0 && !todo.empty?
      host_id = todo.shift
      bud Prog::DownloadCloudHypervisor, {"subject_id" => host_id, "version" => version}
      in_progress.push(host_id)
      slots_to_fill -= 1
    end

    strand.modified!(:stack)
    strand.save_changes

    nap 15
  end

  label def next_stage
    todo.concat(stages.shift)
    strand.modified!(:stack)
    hop_wait
  end

  label def cancel
    reap { pop "rollout cancelled" }
  end
end
