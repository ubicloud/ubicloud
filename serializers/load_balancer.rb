# frozen_string_literal: true

class Serializers::LoadBalancer < Serializers::Base
  def self.serialize_internal(lb, options = {})
    base = {
      id: lb.ubid,
      name: lb.name,
      location: lb.private_subnet.display_location,
      hostname: lb.hostname,
      algorithm: lb.algorithm,
      stack: lb.stack,
      health_check_endpoint: lb.health_check_endpoint,
      health_check_protocol: lb.health_check_protocol,
      src_port: lb.ports&.first&.src_port,
      dst_port: lb.ports&.first&.dst_port
    }

    if options[:include_path]
      base[:path] = lb.path
    end

    if options[:detailed]
      base[:subnet] = lb.private_subnet.name
      base[:vms] = lb.vms.map { it.ubid } || []
    end

    if options[:vms_serialized]
      base[:vms] = Serializers::Vm.serialize(lb.vms_dataset.eager(:location).all, {load_balancer: true})
    end

    base
  end
end
