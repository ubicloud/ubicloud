# frozen_string_literal: true

UbiCli.on("al", "list") do
  desc "List project audit log entries"

  fields = %w[id at action ubid_type subject_id object_ids].freeze
  key = :audit_log_list

  options("ubi al list [options]", key:) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-N", "--no-headers", "do not show headers")
    on("-o", "--object=object", "only show entries affecting the given object UBID")
    on("-s", "--subject=subject", "only show entries with the given subject UBID")
  end
  help_option_values("Fields:", fields)

  run do |opts, command|
    opts = opts[key]
    items = sdk.audit_log.list(subject: opts[:subject], object: opts[:object])
    items = items.map { it.merge(object_ids: Array(it[:object_ids]).join(", ")) }
    keys = underscore_keys(check_fields(opts[:fields], fields, "al list -f option", command))
    response(format_rows(keys, items, headers: opts[:"no-headers"] != false))
  end
end
