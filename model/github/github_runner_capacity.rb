# frozen_string_literal: true

require_relative "../../model"

class GithubRunnerCapacity < Sequel::Model
  unrestrict_primary_key

  SPILL = "aws"

  # Each condition reads only the columns of the row it updates. Postgres
  # checks it again on the newest row version after taking the row lock, so
  # concurrent runners never pass on the same stale usage.
  def self.metal_room(amounts, utilization)
    ((Sequel[:used_cores] + amounts[:used_cores]) * 100 <= Sequel[:total_cores] * utilization) &
      ((Sequel[:used_hugepages_1g] + amounts[:used_hugepages_1g]) * 100 <= Sequel[:total_hugepages_1g] * utilization)
  end

  def self.spill_room(amounts)
    (Sequel[:used_vcpus] + amounts[:used_vcpus] <= Config.github_runner_aws_spill_vcpu_capacity) &
      (Sequel[:used_runners] + amounts[:used_runners] <= Config.github_runner_aws_spill_runner_capacity)
  end

  def self.charge(name, amounts, condition = nil)
    ds = where(name:)
    ds = ds.where(condition) if condition
    ds.update(amounts.to_h { |column, amount| [column, Sequel[column] + amount] }) == 1
  end

  # Reads the stored counters and their truth in one statement, so both come
  # from one snapshot: host capacity from VmHost.runner_capacity, and usage
  # from the charges of the runners holding each pool.
  def self.reconcile_rows
    runners = DB[:github_runner].join(GithubRunner.capacity_charges_dataset, label: :label)
      .exclude(capacity_pool: nil)
      .select_group(Sequel[:github_runner][:capacity_pool].as(:name))
      .select_append {
        [
          sum(Sequel[:charge][:cores]).as(:cores),
          sum(Sequel[:charge][:hugepages_1g]).as(:hugepages_1g),
          sum(Sequel[:charge][:vcpus]).as(:vcpus),
          count.function.*.as(:runners),
        ]
      }
    dataset
      .left_join(VmHost.dataset.runner_capacity.as(:host), name: Sequel[:github_runner_capacity][:name])
      .left_join(runners.as(:runner), name: Sequel[:github_runner_capacity][:name])
      .select_all(:github_runner_capacity)
      .select_append(
        Sequel[:host][:cores].as(:host_cores), Sequel[:host][:hugepages_1g].as(:host_hugepages_1g),
        Sequel[:runner][:cores].as(:runner_cores), Sequel[:runner][:hugepages_1g].as(:runner_hugepages_1g),
        Sequel[:runner][:vcpus].as(:runner_vcpus), Sequel[:runner][:runners].as(:runner_runners),
      )
      .order(Sequel[:github_runner_capacity][:name])
      .all
  end

  # Adds each counter's drift to it, instead of overwriting it with the truth.
  # Every writer changes a counter and the row it counts in one transaction, so
  # a write committed before the snapshot is in both the counter and the truth,
  # and one committed after is in neither and lands on top of the correction.
  # Overwriting would lose those later writes. This needs a single reconciler.
  def self.reconcile(rows = reconcile_rows)
    rows.each do |row|
      spill = row.name == SPILL
      truth = {
        total_cores: row[:host_cores].to_i,
        total_hugepages_1g: row[:host_hugepages_1g].to_i,
        used_cores: spill ? 0 : row[:runner_cores].to_i,
        used_hugepages_1g: spill ? 0 : row[:runner_hugepages_1g].to_i,
        used_vcpus: spill ? row[:runner_vcpus].to_i : 0,
        used_runners: spill ? row[:runner_runners].to_i : 0,
      }
      drift = truth.to_h { |column, value| [column, value - row[column]] }.reject { |_, amount| amount.zero? }
      where(name: row.name).update(reconciled_at: Sequel::CURRENT_TIMESTAMP, **drift.to_h { |column, amount| [column, Sequel[column] + amount] })
      Clog.emit("github runner capacity drift", {github_runner_capacity_drift: {name: row.name, **drift}}) unless drift.empty?
    end
  end

  # A missed or repeated release must never fail a runner's teardown, so the
  # usage stops at zero and the reconciler corrects it.
  def self.refund(name, amounts)
    where(name:).update(amounts.to_h { |column, amount| [column, Sequel.function(:greatest, Sequel[column] - amount, 0)] })
  end

  # Moves a host's capacity from one pool row to another. Either side is nil
  # for a host that leaves or joins the runner capacity, and rows are updated
  # in name order to keep the lock order fixed.
  def self.move_host_capacity(from, to)
    deltas = Hash.new { |h, k| h[k] = [0, 0] }
    [[from, -1], [to, 1]].each do |capacity, sign|
      next unless capacity
      deltas[capacity[:name]][0] += sign * capacity[:cores]
      deltas[capacity[:name]][1] += sign * capacity[:hugepages_1g]
    end

    deltas.sort.each do |name, (cores, hugepages)|
      next if cores == 0 && hugepages == 0
      where(name:).update(total_cores: Sequel[:total_cores] + cores, total_hugepages_1g: Sequel[:total_hugepages_1g] + hugepages)
    end
  end
end

# Table: github_runner_capacity
# Columns:
#  name               | text                     | PRIMARY KEY
#  total_cores        | integer                  | NOT NULL DEFAULT 0
#  total_hugepages_1g | integer                  | NOT NULL DEFAULT 0
#  used_cores         | integer                  | NOT NULL DEFAULT 0
#  used_hugepages_1g  | integer                  | NOT NULL DEFAULT 0
#  used_vcpus         | integer                  | NOT NULL DEFAULT 0
#  used_runners       | integer                  | NOT NULL DEFAULT 0
#  reconciled_at      | timestamp with time zone |
# Indexes:
#  github_runner_capacity_pkey | PRIMARY KEY btree (name)
