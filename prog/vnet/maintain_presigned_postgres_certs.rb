# frozen_string_literal: true

class Prog::Vnet::MaintainPresignedPostgresCerts < Prog::Vnet::MaintainPresignedCerts
  STRAND_ID = "ffffffff-ff00-833a-802d-005b0ec86150" # stzzzzzzzz021g0pg0pres1gn1

  label :wait
  label :request_cert
  label :wait_for_signed_cert

  def generate_ubid
    PostgresResource.generate_ubid
  end

  def id_key
    "postgres_resource_id"
  end

  def domain
    @domain ||= Config.postgres_service_hostname
  end

  def dns_zone
    @dns_zone ||= DnsZone[project_id: Config.postgres_service_project_id, name: domain]
  end

  def ds
    @ds ||= DB[:presigned_postgres_cert]
  end
end
