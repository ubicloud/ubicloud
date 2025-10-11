# frozen_string_literal: true

UbiCli.on("gh").run_on("remove-cache-entry") do
  desc "Remove cache entry for a GitHub repository"

  banner "ubi gh installation-name/repository-name remove-cache-entry cache-entry-id"

  args 1

  run do |id, _, cmd|
    check_no_slash(id, "invalid cache entry id format, should not include /", cmd)
    @repository.remove_cache_entry(id)
    response("Cache entry, if it exists, is now scheduled for destruction")
  end
end
