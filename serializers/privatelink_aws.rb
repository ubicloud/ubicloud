# frozen_string_literal: true

class Serializers::PrivatelinkAws < Serializers::Base
  def self.serialize_internal(pl, options = {})
    base = {
      id: pl.ubid,
      state: pl.display_state,
      subnet_id: pl.private_subnet.ubid,
      service_name: pl.service_name,
      service_id: pl.service_id
    }

    if options[:detailed]
      base.merge!(
        ports: pl.ports.map { |port|
          {
            id: port.ubid,
            src_port: port.src_port,
            dst_port: port.dst_port
          }
        },
        vms: pl.vms.map { |vm|
          pl_vm = pl.privatelink_aws_vms_dataset[vm_id: vm.id]
          # Aggregate state across all ports for this VM
          states = pl_vm.vm_ports.map(&:state).uniq
          aggregate_state = if states.include?("deregistering")
            "removing"
          elsif states.include?("registering")
            "adding"
          elsif states.all? { |s| s == "registered" }
            "registered"
          else
            "unknown"
          end

          {
            id: vm.ubid,
            name: vm.name,
            state: aggregate_state
          }
        }
      )
    end

    base
  end
end
