# frozen_string_literal: true

UbiCli.on("gh").run_on("remove-all-cache-entries") do
  desc "Remove all cache entries for a GitHub repository"

  banner "ubi gh installation-name/repository-name remove-all-cache-entries"

  run do
    @repository.remove_all_cache_entries
    response("All cache entries, if they exist, are now scheduled for destruction")
  end
end
