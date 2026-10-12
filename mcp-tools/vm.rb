# frozen_string_literal: true

module UbiMcp
  module Tools
    class ListVm < Tool
      tool_name "list_vm"
      description "List virtual machines in the project with name, state, size, public IPv4/IPv6 and boot image."
      input_schema(
        properties: {
          location: LOCATION_PROPERTY,
          limit: LIMIT_PROPERTY,
          cursor: CURSOR_PROPERTY,
        },
        additionalProperties: false,
      )

      def self.run(adapter, location: nil, limit: 50, cursor: nil)
        paged(adapter, location_path(location, "vm"), prefix: "vm", limit:, cursor:)
      end
    end

    class GetVm < Tool
      tool_name "get_vm"
      description "Details of one virtual machine: state, size, boot image, public and private IPv4/IPv6, subnet name, attached firewalls with their rules, and GPU if any."
      input_schema(
        properties: {
          ref: ref_property("vm"),
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:)
        adapter.get(resource_path(adapter, "vm", ref, prefix: "vm"))
      end
    end
  end
end
