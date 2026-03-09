# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "audit-log") do |r|
    authorize("Project:auditlog", @project)

    r.get true do
      ds = DB[:audit_log].where(project_id: @project.id).order(Sequel.desc(:at))
      skip_query = false

      if (subject = typecast_params.nonempty_str("subject"))
        if (subject_id = UBID.to_uuid(subject))
          ds = ds.where(subject_id:)
        elsif (subject_id = @project.accounts_dataset.where(Sequel[{name: subject}] | {email: subject}).get(:id))
          ds = ds.where(subject_id:)
        else
          skip_query = true
        end
      end

      if (object = typecast_params.nonempty_str("object"))
        if (object_id = UBID.to_uuid(object))
          ds = ds.where(Sequel.pg_array_op(:object_ids).contains(Sequel.pg_array([object_id], :uuid)))
        else
          skip_query = true
        end
      end

      items = if skip_query
        []
      else
        ds.limit(100).all
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
          log[:at] = log[:at].iso8601

          subject_id = log[:subject_id]
          subject_ubid = UBID.from_uuidish(subject_id).to_s
          subject_name = ubids[subject_id]&.name || subject_ubid
          log[:subject] = "<a class=\"text-orange-600\" href=\"?subject=#{subject_ubid}\">#{subject_name}</a>"

          log[:objects] = log[:object_ids].filter_map do |object_id|
            object_ubid = UBID.from_uuidish(object_id).to_s
            if (obj = ubids[object_id]) && obj.respond_to?(:name) && obj.respond_to?(:path)
              "<a class=\"text-orange-600\" href=\"?object=#{object_ubid}\">#{obj.name}</a> (<a class=\"text-orange-600\" href=\"#{@project.path}#{obj.path}\">View</a>)"
            else
              "<a class=\"text-orange-600\" href=\"?object=#{object_ubid}\">#{object_ubid}</a>"
            end
          end
        end

        @audit_logs = items
        view "project/audit_log"
      end
    end
  end
end
