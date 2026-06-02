# frozen_string_literal: true

class Prog::Vnet::MaintainPresignedLoadBalancerCerts < Prog::Vnet::MaintainPresignedCerts
  STRAND_ID = "ffffffff-ff00-833a-8002-b05b0ec86150" # stzzzzzzzz021g01b0pres1gn1

  label :wait
  label :request_cert
  label :wait_for_signed_cert

  def generate_ubid
    LoadBalancer.generate_ubid
  end

  def id_key
    "load_balancer_id"
  end

  def domain
    @domain ||= Config.load_balancer_service_hostname_v2
  end

  def dns_zone
    @dns_zone ||= DnsZone[project_id: Config.load_balancer_service_project_id, name: domain]
  end

  def ds
    @ds ||= DB[:presigned_load_balancer_cert]
  end
end
