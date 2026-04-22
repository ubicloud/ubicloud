# frozen_string_literal: true

UbiCli.on("mi").run_on("list-versions") do
  desc "List versions of a machine image"

  fields = %w[version id state actual-size-mib archive-size-mib created-at].freeze.each(&:freeze)

  key = :mi_list_versions

  options("ubi mi (location/mi-name | mi-id) list-versions [options]", key:) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-N", "--no-headers", "do not show headers")
  end
  help_option_values("Fields:", fields)

  run do |opts, cmd|
    opts = opts[key]
    versions = sdk_object.list_versions
    keys = underscore_keys(check_fields(opts[:fields], fields, "mi list-versions -f option", cmd))
    response(format_rows(keys, versions, headers: opts[:"no-headers"] != false))
  end
end
