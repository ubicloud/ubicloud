# frozen_string_literal: true

require_relative "../model"

# The subnet is fixed at creation: project_id and location_id are pinned to
# the subnet's by a composite foreign key, and the name is unique per project
# and location. Provider state lives on PrivateLinkServiceAwsResource.
class PrivateLinkService < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location
  many_to_one :private_subnet
  many_to_one :postgres_resource
  one_to_many :ports, class: :PrivateLinkServicePort, order: :port
  one_to_one :private_link_service_aws_resource, key: :id, read_only: true

  plugin :association_dependencies, ports: :destroy, private_link_service_aws_resource: :destroy
  plugin ResourceMethods
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :destroy, :reconcile, :update_permissions, :reconcile_connections
  dataset_module Pagination

  def display_location
    location.display_name
  end

  def before_update
    if (changed_columns & [:private_subnet_id, :project_id, :location_id]).any?
      fail "A private link service cannot move to another private subnet"
    end
    super
  end

  def path
    "/location/#{display_location}/private-link-service/#{name}"
  end

  # The provider nexus classifies its own labels.
  def display_state
    return "deleting" if destroy_set? || strand.nil?

    prog = Object.const_get("Prog::#{strand.prog}")
    return "deleting" if prog::DESTROY_LABELS.include?(strand.label)
    return "available" if prog::BACKGROUND_LABELS.include?(strand.label)

    "creating"
  end

  # The attached resource's current primary; empty without one.
  def target_vms
    [postgres_resource&.representative_server&.vm].compact
  end

  def update_allowed_principals(principals)
    update(allowed_principals: Sequel.pg_array(principals.map(&:strip).uniq, :text))
    incr_update_permissions
  end

  # The domain AWS verifies: a wildcard name (*.example.com) is verified at
  # example.com.
  def private_dns_domain
    private_dns_name&.delete_prefix("*.")
  end

  def self.served_dns_zone_ids
    DB[:dns_servers_dns_zones].join(:dns_servers_vms, dns_server_id: :dns_server_id).select(:dns_zone_id)
  end

  def self.dns_zone_served?(zone)
    !served_dns_zone_ids.where(dns_zone_id: zone.id).empty?
  end

  # Longest match wins; served_only: false also finds a zone that lost its servers.
  def self.managed_dns_zone_for(domain, served_only: true)
    return unless domain

    labels = domain.split(".")
    candidates = labels.each_index.map { labels[it..].join(".") }
    zones = DnsZone.where(name: candidates)
    zones = zones.where(id: served_dns_zone_ids) if served_only
    zones.reverse(Sequel.function(:length, :name)).first
  end

  def managed_private_dns_zone
    PrivateLinkService.managed_dns_zone_for(private_dns_domain)
  end

  # The wildcard SAN of the resource's certificate, so a consumer resolving the
  # resource's private hostname through the endpoint passes verify-full.
  def self.default_private_dns_name(pg)
    return unless pg && pg.hostname_version == "v3" && (zone = pg.dns_zone) && dns_zone_served?(zone)

    pg.cert_private_hostname
  end

  # A resource without a DNS zone answers with its primary's address, so
  # nothing until that primary exists.
  def private_hostname
    return unless (pg = postgres_resource)

    pg.private_hostname if pg.dns_zone || pg.representative_server
  end

  # The row lock serializes concurrent attaches.
  def attach_postgres_resource(pg)
    DB.transaction do
      lock!
      if postgres_resource_id
        fail Validation::ValidationFailed.new("postgres_resource_id" => "A PostgreSQL resource is already attached")
      end

      update(postgres_resource_id: pg.id, private_dns_name: PrivateLinkService.default_private_dns_name(pg))
      forget_private_dns_verification
      incr_reconcile
    end
  end
end

# Table: private_link_service
# Columns:
#  id                   | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(725)
#  created_at           | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id           | uuid                     | NOT NULL
#  location_id          | uuid                     | NOT NULL
#  private_subnet_id    | uuid                     | NOT NULL
#  postgres_resource_id | uuid                     |
#  name                 | text                     | NOT NULL
#  allowed_principals   | text[]                   | NOT NULL DEFAULT '{}'::text[]
#  private_dns_name     | text                     |
#  ip_address_type      | text                     | NOT NULL DEFAULT 'ipv4'::text
# Indexes:
#  private_link_service_pkey                            | PRIMARY KEY btree (id)
#  private_link_service_project_id_location_id_name_key | UNIQUE btree (project_id, location_id, name)
#  private_link_service_postgres_resource_id_index      | btree (postgres_resource_id)
# Check constraints:
#  private_link_service_ip_address_type_check | (ip_address_type = ANY (ARRAY['ipv4'::text, 'ipv6'::text, 'dual'::text]))
# Foreign key constraints:
#  private_link_service_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id) ON DELETE SET NULL
#  private_link_service_private_subnet_fkey       | (private_subnet_id, project_id, location_id) REFERENCES private_subnet(id, project_id, location_id)
# Referenced By:
#  private_link_service_aws_resource | private_link_service_aws_resource_id_fkey              | (id) REFERENCES private_link_service(id) ON DELETE CASCADE
#  private_link_service_port         | private_link_service_port_private_link_service_id_fkey | (private_link_service_id) REFERENCES private_link_service(id) ON DELETE CASCADE
