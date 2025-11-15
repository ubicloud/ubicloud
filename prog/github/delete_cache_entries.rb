# frozen_string_literal: true

class Prog::Github::DeleteCacheEntries < Prog::Base
  subject_is :github_repository

  def self.assemble(repository_id, initiated_at: Time.now)
    Strand.create(
      prog: "Github::DeleteCacheEntries",
      label: "delete_entries",
      stack: [{
        "subject_id" => repository_id,
        "initiated_at" => initiated_at.to_s
      }]
    )
  end

  label def delete_entries
    if (cache_entry = next_entry)
      cache_entry.destroy
      nap 0
    end

    pop "all cache entries deleted"
  end

  def next_entry
    initiated_at = Time.parse(frame["initiated_at"])
    github_repository.cache_entries_dataset.order(:created_at).first { created_at < initiated_at }
  end
end
