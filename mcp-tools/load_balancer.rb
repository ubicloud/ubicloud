# frozen_string_literal: true

module UbiMcp
  module Tools
    class ListLoadBalancer < Tool
      tool_name "list_load_balancer"
      description "List load balancers in the project: hostname, ports, algorithm, health check and TLS flag."
      input_schema(
        properties: {
          location: LOCATION_PROPERTY,
          limit: LIMIT_PROPERTY,
          cursor: CURSOR_PROPERTY,
        },
        additionalProperties: false,
      )

      def self.run(adapter, location: nil, limit: 50, cursor: nil)
        paged(adapter, location_path(location, "load-balancer"), prefix: "1b", limit:, cursor:)
      end
    end

    class GetLoadBalancer < Tool
      tool_name "get_load_balancer"
      description "Details of one load balancer including its subnet and the ids of attached VMs (resolve them with `get_vm`)."
      input_schema(
        properties: {
          ref: ref_property("1b"),
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:)
        adapter.get(resource_path(adapter, "load-balancer", ref, prefix: "1b"))
      end
    end
  end
end
