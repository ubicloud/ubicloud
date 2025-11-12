# frozen_string_literal: true

class Prog::Github::DeleteCacheEntries < Prog::Base
  subject_is :github_repository

  def self.assemble(repository_id, initiated_at = Time.now)
    DB.transaction do
      strand = Strand.create_with_id(
        repository_id,
        prog: "Github::DeleteCacheEntries",
        label: "start",
        stack: [{
          "subject_id" => repository_id,
          "initiated_at" => initiated_at.to_s
        }]
      )
      strand
    end
  end

  label def start
    hop_delete_entries
  end

  label def delete_entries
    cache_entry = github_repository.cache_entries_dataset.first

    unless cache_entry
      pop "all cache entries deleted"
    end

    cache_entry.destroy

    nap 0
  end
end
