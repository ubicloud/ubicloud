# frozen_string_literal: true

class Serializers::LoadBalancer < Serializers::Base
  def self.serialize_internal(lb, options = {})
    base = {
      id: lb.ubid,
      name: lb.name,
      location: lb.private_subnet.display_location,
      hostname: lb.hostname,
      algorithm: lb.algorithm,
      stack: lb.stack
    }

    base[:ports] = lb.ports.map do |port|
      {
        health_check_endpoint: port.health_check_endpoint,
        health_check_protocol: port.health_check_protocol,
        src_port: port.src_port,
        dst_port: port.dst_port
      }
    end

    if options[:include_path]
      base[:path] = lb.path
    end

    if options[:detailed]
      base[:subnet] = lb.private_subnet.name
      base[:vms] = lb.vms.map { _1.ubid } || []
    end

    if options[:vms_serialized]
      base[:vms] = Serializers::Vm.serialize(lb.vms, {load_balancer: true})
    end

    base
  end
end
