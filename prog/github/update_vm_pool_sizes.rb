# frozen_string_literal: true

# Periodically turns the live per-label demand estimate (GithubRunnerDemandStat,
# updated by GithubRunnerDemandStat.track_arrival/track_completion) into
# VmPool#size updates for pools that already exist. Deciding when a
# currently-unpooled label earns a brand-new pool is a separate, deliberately
# out-of-scope follow-up - this only resizes pools ops already created.
#
# The existing capacity-gated replenishment in Prog::Vm::VmPool#wait is the
# real safety backstop and is untouched by this; vm_pool_size_ceiling here is
# just a conservative belt-and-suspenders cap for the first rollout.
class Prog::Github::UpdateVmPoolSizes < Prog::Base
  label def wait
    decay_stale_stats
    resize_pools

    nap 60
  end

  private

  def decay_stale_stats
    stale_before = Time.now - 60
    alpha = Config.vm_pool_ewma_rate_alpha

    GithubRunnerDemandStat
      .where { last_arrival_at < stale_before }
      .update(ewma_rate: Sequel[:ewma_rate] * (1 - alpha))
  end

  def resize_pools
    GithubRunnerDemandStat.all.each do |stat|
      label_data = Github.runner_labels[stat.label]
      next unless label_data

      VmPool.where(vm_size: label_data["vm_size"], arch: stat.arch).update(size: stat.target_size)
    end
  end
end
