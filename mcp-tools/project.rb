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
  end
end
