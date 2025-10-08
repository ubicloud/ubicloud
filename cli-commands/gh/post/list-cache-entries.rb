# frozen_string_literal: true

UbiCli.on("gh").run_on("list-cache-entries") do
  desc "List cache entries for a GitHub repository"

  key = :cache_entries_list

  options("ubi gh installation-name/repository-name list-cache-entries [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    cache_entries = @repository.cache_entries.each { it.values[:size] = Clover.humanize_size(it[:size]) }
    response(format_rows(%i[id size key], cache_entries, headers: opts[key][:"no-headers"] != false))
  end
end
