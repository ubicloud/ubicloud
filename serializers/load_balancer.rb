# frozen_string_literal: true

class Serializers::LoadBalancer < Serializers::Base
  def self.serialize_internal(lb, options = {})
    base = {
      id: lb.ubid,
      name: lb.name,
      hostname: lb.hostname,
      algorithm: (lb.algorithm == "round_robin") ? "Round Robin" : "Hash Based",
      health_check_endpoint: lb.health_check_endpoint,
      src_port: lb.src_port,
      dst_port: lb.dst_port
    }

    if options[:include_path]
      base[:path] = lb.path
    end

    if options[:detailed]
      base[:subnet] = Serializers::PrivateSubnet.serialize(lb.private_subnet, {include_path: true})
      base[:vms] = Serializers::Vm.serialize(lb.vms, {load_balancer: true})
    end

    base
  end
end
