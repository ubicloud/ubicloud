# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "audit-log") do |r|
    authorize("Project:auditlog", @project)

    r.get true do
      ds = DB[:audit_log].where(project_id: @project.id).order(Sequel.desc(:at), :id, :ubid_type, :action)
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
        elsif (subject_id = @project.accounts_dataset.where(Sequel[{name: subject}] | {email: subject}).get(:id))
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

      # How many months to show for a single request
      @month_limit = month_limit = 3

      today = Date.today
      begin
        end_date = typecast_params.date("end")
      rescue Roda::RodaPlugins::TypecastParams::Error
        bad_date = true
      else
        # Limit access to the prior 6 months by default
        # (min date 3 months ago, showing the previous 3 months)
        min_end_date = today << month_limit
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

        # 1746082800.0 is May 1, 2025, before audit logging was added
        ds = if (key = typecast_params.nonempty_str("pagination_key")) &&
            (before, start_id = key.split("/", 2)) &&
            start_id &&
            (start_id = UBID.to_uuid(start_id)) &&
            (before = before.to_f) > 1746082800
          end_time = Time.at(before.to_r.round(6))
          ds.where(Sequel[at: start_date.to_time...end_time] | (Sequel[at: end_time] & (Sequel[:id] >= start_id)))
        else
          ds.where(at: start_date...(end_date + 1))
        end
      end

      if (limit = typecast_params.pos_int("limit"))
        next_page_params["limit"] = limit
      end

      limit ||= 100
      limit = limit.clamp(1, 100) + 1

      if skip_query
        items = []
      else
        items = ds.limit(limit).all
        if items.length == limit
          before_id = UBID.from_uuidish(items.pop[:id]).to_s
          @pagination_key = "#{items.last[:at].strftime("%s.%6N")}/#{before_id}"
        end
      end

      if api?
        {items: Serializers::AuditLog.serialize(items)}
      else
        ubids = {}

        items.each do |log|
          ubids[log[:subject_id]] = nil
          log[:object_ids].each do
            ubids[it] = nil
          end
        end

        UBID.resolve_map(ubids) do |ds|
          ds = ds.where(projects: @project) if ds.model == Account
          ds = ds.eager(:location) if ds.model.association_reflection(:location)
          ds
        end

        items.each do |log|
          subject_id = log[:subject_id]
          subject_ubid = UBID.from_uuidish(subject_id).to_s
          subject_name = ubids[subject_id]&.name || subject_ubid
          log[:subject] = "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;subject=#{h subject_ubid}\">#{h subject_name}</a>"

          log[:objects] = log[:object_ids].filter_map do |object_id|
            object_ubid = UBID.from_uuidish(object_id).to_s
            if (obj = ubids[object_id]) && obj.respond_to?(:name) && obj.respond_to?(:path)
              "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;object=#{h object_ubid}\">#{h obj.name}</a> (<a class=\"text-orange-600\" href=\"#{@project.path}#{obj.path}\">View</a>)"
            else
              "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;object=#{h object_ubid}\">#{h object_ubid}</a>"
            end
          end
        end

        @audit_logs = items
        view "project/audit_log"
      end
    end
  end
end
