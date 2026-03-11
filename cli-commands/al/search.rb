# frozen_string_literal: true

UbiCli.on("al", "search") do
  desc "Search project audit log entries in CSV format"

  key = :audit_log_search

  options("ubi al search [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
    on("-a", "--action=action", "only show entries for the given action")
    on("-e", "--end=end-date", "only show prior to end date")
    on("-o", "--object=object", "only show entries affecting the given object ID")
    on("-s", "--subject=account", "only show entries with the given account name/email/ID")
    on("--limit=limit", "limit number of records returned")
    on("--pagination-key=key", "continue a previous search")
  end

  run do |opts, command|
    opts = underscore_keys(opts[key])
    no_headers = opts.delete(:no_headers)
    logs = sdk.audit_log.search(**opts)

    body = []

    if no_headers != false
      body << "At,Action,Account,Objects\n"
    end

    logs.each do |log|
      body <<
        log.at << "," <<
        log.action << "," <<
        (log.subject_name || log.subject_id) << ","

      log.object_ids.each do
        body << it << " "
      end

      body << "\n"
    end

    if logs.next_page_args
      body << "Continue search: ubi al search "
      logs.next_page_args.each do |key, value|
        if value
          body << "--" << key.to_s.tr("_", "-") << "=" << value.to_s << " "
        end
      end
      body << "\n"
    end

    response(body)
  end
end
