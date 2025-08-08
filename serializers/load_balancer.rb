# frozen_string_literal: true

class Serializers::LoadBalancer < Serializers::Base
  def self.serialize_internal(lb, options = {})
    base = {
      id: lb.ubid,
      name: lb.name,
      location: lb.display_location,
      hostname: lb.hostname,
      algorithm: lb.algorithm,
      stack: lb.stack,
      health_check_endpoint: lb.health_check_endpoint,
      health_check_protocol: lb.health_check_protocol,
      src_port: lb.src_port,
      dst_port: lb.dst_port
    }

    if options[:detailed]
      base[:subnet] = lb.private_subnet.name
      base[:vms] = lb.vms.map { it.ubid } || []
    end

    base
  end
end
