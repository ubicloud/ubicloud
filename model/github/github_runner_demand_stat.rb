# frozen_string_literal: true

require_relative "../../model"

class GithubRunnerDemandStat < Sequel::Model
  plugin ResourceMethods, etc_type: true

  # Called when a runner is requested (webhook "queued" action). Samples the
  # gap since the last arrival of this label into a rate EWMA. GithubRunner
  # rows are hard-deleted on completion, so there's no history table this
  # could be derived from after the fact - it has to be tracked live.
  def self.track_arrival(label)
    arch = Github.runner_labels.dig(label, "arch")
    return unless arch

    now = Time.now
    stat = find_or_create(label:, arch:)

    if stat.last_arrival_at.nil?
      where(id: stat.id).update(last_arrival_at: now, updated_at: now)
      return
    end

    gap = [now - stat.last_arrival_at, 0.001].max
    rate_sample = 1.0 / gap
    alpha = Config.vm_pool_ewma_rate_alpha

    where(id: stat.id).update(
      ewma_rate: Sequel[:ewma_rate] * (1 - alpha) + rate_sample * alpha,
      last_arrival_at: now, updated_at: now,
    )
  end

  # Called when a runner finishes (right before its GithubRunner row is
  # destroyed). Samples its actual duration into a hold-time EWMA. Best
  # effort: if no stat row exists yet for this label/arch, this is a no-op
  # (0 rows affected), never an error - this is telemetry, not something
  # that should ever block runner cleanup.
  def self.track_completion(label, hold_time_seconds)
    arch = Github.runner_labels.dig(label, "arch")
    return unless arch

    alpha = Config.vm_pool_ewma_hold_alpha
    where(label:, arch:).update(
      ewma_hold_time: Sequel[:ewma_hold_time] * (1 - alpha) + hold_time_seconds * alpha,
      updated_at: Time.now,
    )
  end

  def target_size
    (ewma_rate * ewma_hold_time * Config.vm_pool_ewma_safety_factor).ceil.clamp(Config.vm_pool_size_floor, Config.vm_pool_size_ceiling)
  end
end

# Table: github_runner_demand_stat
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  label           | text                     | NOT NULL
#  arch            | arch                     | NOT NULL DEFAULT 'x64'::arch
#  ewma_rate       | double precision         | NOT NULL DEFAULT 0
#  ewma_hold_time  | double precision         | NOT NULL DEFAULT 0
#  last_arrival_at | timestamp with time zone |
#  updated_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  github_runner_demand_stat_pkey           | PRIMARY KEY btree (id)
#  github_runner_demand_stat_label_arch_key | UNIQUE btree (label, arch)
