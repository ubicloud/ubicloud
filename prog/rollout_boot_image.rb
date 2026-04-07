# frozen_string_literal: true

class Prog::RolloutBootImage < Prog::Base
  semaphore :rollback, :pause

  def self.assemble(vm_hosts:, concurrency:, image_name:, version:)
    todo = vm_hosts.sort_by(&:created_at).map(&:id)
    Strand.create(
      prog: "RolloutBootImage",
      label: "wait",
      stack: [{
        "todo" => todo,
        "in_progress" => [],
        "completed" => [],
        "failures" => {},
        "concurrency" => concurrency,
        "image_name" => image_name,
        "version" => version,
      }],
    )
  end

  def image_name
    @image_name ||= frame.fetch("image_name")
  end

  def version
    @version ||= frame.fetch("version")
  end

  def concurrency
    @concurrency ||= frame.fetch("concurrency")
  end

  def todo
    frame.fetch("todo")
  end

  def in_progress
    frame.fetch("in_progress")
  end

  def completed
    frame.fetch("completed")
  end

  def failures
    frame.fetch("failures")
  end

  label def wait
    when_rollback_set? do
      hop_rollback
    end

    when_pause_set? do
      nap 60 * 60
    end

    reaper = lambda do |child|
      host_id = child.stack.first["subject_id"]
      in_progress.delete(host_id)
      case child.exitval["msg"]
      when "image downloaded", "Image already exists on host"
        completed.push(host_id)
      else
        failures[host_id] = (failures[host_id] || 0) + 1
        todo.push(host_id)
      end
    end

    reap(fallthrough: true, reaper:) do
      pop "rollout completed" if todo.empty? && in_progress.empty?
    end

    # Fill concurrency slots from the todo queue
    slots_to_fill = concurrency - strand.children_dataset.count
    while slots_to_fill > 0 && !todo.empty?
      host_id = todo.shift
      bud Prog::DownloadBootImage, {"subject_id" => host_id, "image_name" => image_name, "version" => version, "exit_on_fail" => true}
      in_progress.push(host_id)
      slots_to_fill -= 1
    end

    strand.modified!(:stack)
    strand.save_changes

    nap 15
  end

  label def rollback
    Semaphore.incr(strand.children_dataset.select(:id), :cancel)
    reap(:remove_downloaded_images)
  end

  label def remove_downloaded_images
    all_host_ids = todo + in_progress + completed
    BootImage.where(vm_host_id: all_host_ids, name: image_name, version:).each(&:remove_boot_image)
    pop "rollout rolled back"
  end
end
