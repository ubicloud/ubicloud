# frozen_string_literal: true

# Picks the runners without capacity in a scheduling round that spill to
# AWS. A runner waits from when its VM entered the allocation queue, so
# runners held back by their own concurrency limit do not count as
# waiting. Runners that waited past the spill threshold spill longest
# waiting first, then largest first, while the spills stay within the
# global AWS spill capacity and each installation within its share of it.
class Scheduling::RunnerSpiller
  def initialize
    spilled_vcpus, spilled_runners = GithubRunner.aws_vm_usage
    @free_vcpus = Config.github_runner_aws_spill_vcpu_capacity - spilled_vcpus
    @free_runners = Config.github_runner_aws_spill_runner_capacity - spilled_runners
    @installation_vcpus = GithubRunner.aws_vcpus_by_installation
    @installation_vcpu_limit = Config.github_runner_aws_spill_vcpu_capacity * Config.central_vm_scheduler_spill_installation_share
  end

  # Returns the ids of the VMs whose runners spilled.
  def spill(vm_ids)
    return [] unless @free_vcpus > 0 && @free_runners > 0

    GithubRunner.where(vm_id: vm_ids).eager(:vm, installation: :project).all
      .select { spillable?(it) }
      .sort_by { [it.vm.created_at, -it.label_data["vcpus"]] }
      .filter_map do |runner|
        next unless fits?(runner)

        spill_runner(runner)
        runner.vm_id
      end
  end

  private

  def spillable?(runner)
    runner.support_alien? &&
      Time.now - runner.vm.created_at > Config.github_runner_aws_spill_threshold_seconds &&
      runner.installation.project.get_ff_spill_to_alien_runners &&
      runner.aws_quota_available?
  end

  def fits?(runner)
    runner.aws_vcpus <= @free_vcpus &&
      @free_runners > 0 &&
      @installation_vcpus.fetch(runner.installation_id, 0) + runner.aws_vcpus <= @installation_vcpu_limit
  end

  def spill_runner(runner)
    @free_vcpus -= runner.aws_vcpus
    @free_runners -= 1
    @installation_vcpus[runner.installation_id] = @installation_vcpus.fetch(runner.installation_id, 0) + runner.aws_vcpus
    runner.incr_spill_over
    Clog.emit("central vm scheduler spilled runner", {central_vm_scheduler_spill: {runner: runner.ubid, label: runner.label, installation: runner.installation.ubid, waited: (Time.now - runner.vm.created_at).round(1)}})
  end
end
