# frozen_string_literal: true

module AuditLog
  def audit_log_search(ds, accounts_dataset:, resolve:, month_limit:, min_end_date: Date.today << month_limit)
    ds = ds.order(Sequel.desc(:at), :id, :ubid_type, :action)
    skip_query = false
    next_page_params = @next_page_params = {}

    if (action = typecast_params.nonempty_str("action"))
      next_page_params["action"] = action
      type, action = action.split("/")
      ds = if action
        ds.where(ubid_type: type, action:)
      else
        ds.where(type => [:ubid_type, :action])
      end
    end

    if (subject = typecast_params.nonempty_str("subject"))
      next_page_params["subject"] = subject
      if (subject_id = UBID.to_uuid(subject))
        ds = ds.where(subject_id:)
      elsif (subject_id = accounts_dataset.where(Sequel[{name: subject}] | {email: subject}).get(:id))
        ds = ds.where(subject_id:)
      else
        skip_query = true
      end
    end

    if (object = typecast_params.nonempty_str("object"))
      next_page_params["object"] = object
      if (object_id = UBID.to_uuid(object))
        ds = ds.where(Sequel.pg_array_op(:object_ids).contains(Sequel.pg_array([object_id], :uuid)))
      else
        skip_query = true
      end
    end

    default_limit = (resolve == :subjects_and_objects) ? 100 : 1000
    fetch_audit_log_entries(ds, next_page_params:, default_limit:, skip_query:, month_limit:, min_end_date:)

    ubids = {}

    case resolve
    when :subjects_and_objects
      @audit_logs.each do |log|
        ubids[log[:subject_id]] = nil
        log[:object_ids].each do
          ubids[it] = nil
        end
      end

      UBID.resolve_map(ubids) do |ds|
        ds = ds.where(id: accounts_dataset.select(Sequel[:accounts][:id])) if ds.model == Account
        ds = ds.eager(:location) if ds.model.association_reflection(:location)
        ds
      end
    when :subjects
      @audit_logs.each do |log|
        ubids[log[:subject_id]] = nil
      end

      UBID.resolve_map(ubids) do |ds|
        ds.where(id: accounts_dataset.select(Sequel[:accounts][:id]))
      end
    end

    @ubids = ubids

    nil
  end

  def authentication_audit_log_search(ds, month_limit:, accounts_dataset: nil, resolve: nil, min_end_date: Date.today << month_limit)
    ds = ds.order(Sequel.desc(:at), :id)
    skip_query = false
    next_page_params = @next_page_params = {}

    if (message = typecast_params.nonempty_str("action"))
      next_page_params["action"] = message
      ds = ds.where(message:)
    end

    if (metadata = typecast_params.nonempty_str("metadata"))
      next_page_params["metadata"] = metadata
      begin
        ds = ds.where(Sequel.pg_jsonb_op(:metadata).contains(Sequel.pg_jsonb(JSON.parse(metadata))))
      rescue JSON::ParserError
        skip_query = true
      end
    end

    if accounts_dataset && (account = typecast_params.nonempty_str("account"))
      next_page_params["account"] = account
      if (account_id = UBID.to_uuid(account))
        ds = ds.where(account_id:)
      elsif (account_id = accounts_dataset.where(Sequel[{name: account}] | {email: account}).get(:id))
        ds = ds.where(account_id:)
      else
        skip_query = true
      end
    end

    fetch_audit_log_entries(ds, next_page_params:, default_limit: 100, skip_query:, month_limit:, min_end_date:)

    ubids = {}

    if resolve == :accounts && accounts_dataset
      @audit_logs.each { ubids[it[:account_id]] = nil }
      UBID.resolve_map(ubids) do |ds|
        ds.where(id: accounts_dataset.select(Sequel[:accounts][:id]))
      end
    end

    @ubids = ubids

    nil
  end

  private

  def fetch_audit_log_entries(ds, next_page_params:, default_limit:, skip_query:, month_limit:, min_end_date:)
    # How many months to show for a single request
    @month_limit = month_limit

    today = Date.today
    begin
      end_date = typecast_params.date("end")
    rescue Roda::RodaPlugins::TypecastParams::Error
      bad_date = true
    else
      if end_date && end_date.clamp(min_end_date, today >> month_limit) != end_date
        bad_date = true
      end
    end

    if bad_date
      skip_query = true
    else
      end_date ||= today
      @end_date = next_page_params["end"] = end_date
      start_date = end_date << month_limit
      if start_date >= min_end_date
        @next_end_date = start_date
      end
      start_date += 1

      if (key = typecast_params.nonempty_str("pagination_key")) &&
          (before, start_id = key.split("/", 2)) &&
          start_id &&
          (start_id = UBID.to_uuid(start_id))

        begin
          end_time = Time.strptime(before, "%s.%N")
        rescue ArgumentError
          nil
        end
      end

      # 1746082800 is May 1, 2025, before audit logging was added
      ds = if start_id && end_time && end_time.to_i > 1746082800
        ds.where(Sequel[at: start_date.to_time...end_time] | (Sequel[at: end_time] & (Sequel[:id] >= start_id)))
      else
        ds.where(at: start_date...(end_date + 1))
      end
    end

    if (limit = typecast_params.pos_int("limit"))
      next_page_params["limit"] = limit
    end

    limit ||= default_limit
    limit = limit.clamp(1, default_limit) + 1

    if skip_query
      items = []
    else
      items = ds.limit(limit).all
      if items.length == limit
        next_page_item = items.pop
        before_id = UBID.to_ubid(next_page_item[:id])
        @pagination_key = "#{next_page_item[:at].strftime("%s.%6N")}/#{before_id}"
      end
    end

    @audit_logs = items
    @end_date = end_date

    nil
  end
end
