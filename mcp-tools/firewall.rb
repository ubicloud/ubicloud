# frozen_string_literal: true

module UbiMcp
  module Tools
    class ListFirewall < Tool
      tool_name "list_firewall"
      description "List firewalls in the project, each with its rules (cidr, port range, protocol)."
      input_schema(
        properties: {
          location: LOCATION_PROPERTY,
          limit: LIMIT_PROPERTY,
          cursor: CURSOR_PROPERTY,
        },
        additionalProperties: false,
      )

      def self.run(adapter, location: nil, limit: 50, cursor: nil)
        paged(adapter, location_path(location, "firewall"), prefix: "fw", limit:, cursor:)
      end
    end

    class GetFirewall < Tool
      tool_name "get_firewall"
      description "Details of one firewall: its rules and the private subnets it is attached to."
      input_schema(
        properties: {
          ref: ref_property("fw"),
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:)
        adapter.get(resource_path(adapter, "firewall", ref, prefix: "fw"))
      end
    end
  end
end
