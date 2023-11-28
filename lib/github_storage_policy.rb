# frozen_string_literal: true

class GithubStoragePolicy
  def initialize(rules)
    @rules = rules || {}
  end

  def use_bdev_ubi?
    rand < @rules.fetch("use_bdev_ubi_rate", 0.0)
  end

  def skip_sync?
    rand < @rules.fetch("skip_sync_rate", 0.0)
  end
end
