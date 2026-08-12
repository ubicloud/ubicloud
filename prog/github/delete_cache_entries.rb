# frozen_string_literal: true

class Prog::Github::DeleteCacheEntries < Prog::Base
  subject_is :github_repository
  frame_reader :initiated_at, :cache_entry_ids

  def self.assemble(repository_id, initiated_at: Time.now, cache_entry_ids: nil)
    Strand.create(
      prog: "Github::DeleteCacheEntries",
      label: "delete_entries",
      stack: [{
        "subject_id" => repository_id,
        "initiated_at" => initiated_at.to_s,
        "cache_entry_ids" => cache_entry_ids,
      }],
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
    return unless github_repository

    ds = github_repository.cache_entries_dataset

    if cache_entry_ids
      if (gce = ds.first(id: cache_entry_ids))
        strand.modified!(:stack)
        cache_entry_ids.delete(gce.id)
        gce
      end
    else
      ds
        .order(:created_at)
        .first(Sequel[:created_at] < Time.new(initiated_at))
    end
  end
end
