# frozen_string_literal: true

require_relative "../../model"

class GithubRunnerCapacity < Sequel::Model
  unrestrict_primary_key

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
