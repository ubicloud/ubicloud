# frozen_string_literal: true

module UbiMcp
  module Tools
    class ListPrivateSubnet < Tool
      tool_name "list_private_subnet"
      description "List private subnets in the project with their IPv4/IPv6 ranges, attached firewalls and NICs (each NIC names the VM it belongs to)."
      input_schema(
        properties: {
          location: LOCATION_PROPERTY,
          limit: LIMIT_PROPERTY,
          cursor: CURSOR_PROPERTY,
        },
        additionalProperties: false,
      )

      def self.run(adapter, location: nil, limit: 50, cursor: nil)
        paged(adapter, location_path(location, "private-subnet"), prefix: "ps", limit:, cursor:)
      end
    end

    class GetPrivateSubnet < Tool
      tool_name "get_private_subnet"
      description "Details of one private subnet: address ranges, attached firewalls with rules, and NICs with private IPs and the VM each belongs to."
      input_schema(
        properties: {
          ref: ref_property("ps"),
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:)
        adapter.get(resource_path(adapter, "private-subnet", ref, prefix: "ps"))
      end
    end
  end
end
