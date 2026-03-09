# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "audit-log") do |r|
    authorize("Project:auditlog", @project)

    r.get true do
      ds = DB[:audit_log].where(project_id: @project.id).order(Sequel.desc(:at))

      if (subject = typecast_params.nonempty_str("subject"))
        ds = if (subject_uuid = UBID.to_uuid(subject))
          ds.where(subject_id: subject_uuid)
        else
          ds.where(false)
        end
      end

      if (object = typecast_params.nonempty_str("object"))
        ds = if (object_uuid = UBID.to_uuid(object))
          ds.where(Sequel.pg_array_op(:object_ids).contains(Sequel.pg_array([object_uuid], :uuid)))
        else
          ds.where(false)
        end
      end

      items = ds.limit(100).all

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
          ds = ds.eager(:location) if ds.model.association_reflection(:location)
          ds
        end

        items.each do |log|
          subject_id = log[:subject_id]
          log[:at] = log[:at].iso8601
          log[:subject] = ubids[subject_id]&.name || UBID.from_uuidish(subject_id).to_s

          log[:objects] = log[:object_ids].filter_map do
            if (obj = ubids[it]) && obj.respond_to?(:name) && obj.respond_to?(:path)
              "<a class=\"text-orange-600\" href=\"#{@project.path}#{obj.path}\">#{h(obj.name)}</a>"
            else
              UBID.from_uuidish(it)
            end
          end
        end

        @audit_logs = items
        view "project/audit_log"
      end
    end
  end
end
