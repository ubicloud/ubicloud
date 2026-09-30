# frozen_string_literal: true

module UbiMcp
  module Tools
    class GetObjectInfo < Tool
      tool_name "get_object_info"
      description "Resolve the id of a firewall (fw...), Kubernetes cluster (kc...), load balancer (1b...), machine image (m1...), PostgreSQL database (pg...), private subnet (ps...) or VM (vm...) to its type, location and name. Other ids, such as those of accounts, tokens or firewall rules, are rejected."
      input_schema(
        properties: {
          id: {type: "string", description: "Resource id"},
        },
        required: ["id"],
        additionalProperties: false,
      )

      def self.run(adapter, id:)
        object_info(adapter, id)
      end
    end

    class ListAuditLog < Tool
      CURSOR_REGEXP = %r{\A(\d{10})\.\d{6}/(a1[a-z0-9]{24})\z}

      tool_name "list_audit_log"
      description "Who did what in this project, newest first. Each entry has `at`, `action` as type/action, where the type is the id prefix of the main object (a PostgreSQL resize is `pg/update`), `subject_id` (the account), `subject_name` when known and `object_ids`, some of which `get_object_info` resolves. A query searches the 3 months ending on `end`, so only about the last 6 months can be searched. Requires the `Project:auditlog` permission on the token."
      input_schema(
        properties: {
          action: {type: "string", description: "pg/restart, a bare type such as pg, or a bare action such as restart"},
          subject: {type: "string", description: "Account id, name or email"},
          object: {type: "string", description: "Resource id"},
          end: {type: "string", description: "YYYY-MM-DD from 3 months before to 3 months after today (default today; when paging, pass the same end on every call, including the first)"},
          limit: LIMIT_PROPERTY,
          cursor: CURSOR_PROPERTY,
        },
        additionalProperties: false,
      )

      def self.run(adapter, action: nil, subject: nil, object: nil, end: nil, limit: 50, cursor: nil)
        params = {action:, subject:, object:, end:, limit: limit.to_i, pagination_key: cursor}
        if (end_date = params[:end])
          today = Date.today
          range = (today << 3)..(today >> 3)
          raise Invalid, "end must be a YYYY-MM-DD date from #{range.begin} to #{range.end}" unless range.cover?(parse_date(end_date))
        end
        raise Invalid, "cursor must be the next_cursor of a previous result" if cursor && !well_formed_cursor?(cursor)

        page = adapter.get("audit-log", params)
        {items: page[:items], next_cursor: page[:pagination_key]}
      end

      class << self
        private

        def parse_date(value)
          Date.iso8601(value) if /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
        rescue Date::Error
          nil
        end

        # lib/audit_log.rb ignores a pagination key at or before 1746082800
        def well_formed_cursor?(cursor)
          (match = CURSOR_REGEXP.match(cursor)) && match[1].to_i > 1746082800 && UBID.to_uuid(match[2])
        end
      end
    end
  end
end
