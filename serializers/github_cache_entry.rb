# frozen_string_literal: true

class Serializers::GithubCacheEntry < Serializers::Base
  def self.serialize_internal(entry, options = {})
    {
      id: entry.ubid,
      key: entry.key,
      repository: {
        id: entry.repository.ubid,
        name: entry.repository.name
      },
      scope: entry.scope,
      created_at: entry.created_at.strftime("%Y-%m-%d %H:%M UTC"),
      created_at_human: humanize_time(entry.created_at),
      last_accessed_at: entry.last_accessed_at&.strftime("%Y-%m-%d %H:%M UTC"),
      last_accessed_at_human: humanize_time(entry.last_accessed_at),
      size: entry.size,
      size_human: humanize_size(entry.size)
    }
  end

  def self.humanize_size(bytes)
    return nil if bytes.nil? || bytes.zero?
    units = %w[B KB MB GB]
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = [exp, units.size - 1].min

    return "%d %s" % [bytes.to_f / 1024**exp, units[exp]] if exp == 0
    "%.1f %s" % [bytes.to_f / 1024**exp, units[exp]]
  end

  def self.humanize_time(time)
    return nil unless time
    seconds = Time.now - time
    return "just now" if seconds < 60
    return "#{(seconds / 60).to_i} minutes ago" if seconds < 3600
    return "#{(seconds / 3600).to_i} hours ago" if seconds < 86400
    "#{(seconds / 86400).to_i} days ago"
  end
end
