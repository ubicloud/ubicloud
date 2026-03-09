# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "audit-log") do |r|
    authorize("Project:auditlog", @project)

    r.get true do
      ds = DB[:audit_log].where(project_id: @project.id).order(Sequel.desc(:at))

      if (subject = typecast_params.nonempty_str("subject"))
        if (subject_uuid = UBID.to_uuid(subject))
          ds = ds.where(subject_id: subject_uuid)
        else
          ds = ds.where(false)
        end
      end

      if (object = typecast_params.nonempty_str("object"))
        if (object_uuid = UBID.to_uuid(object))
          ds = ds.where(Sequel.pg_array_op(:object_ids).contains(Sequel.pg_array([object_uuid], :uuid)))
        else
          ds = ds.where(false)
        end
      end

      items = ds.limit(100).all

      if api?
        {items: Serializers::AuditLog.serialize(items)}
      else
        @audit_logs = Serializers::AuditLog.serialize(items)
        view "project/audit_log"
      end
    end
  end
end
