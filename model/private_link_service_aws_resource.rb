# frozen_string_literal: true

require_relative "../model"
require "aws-partitions"

# AWS PrivateLink state of a PrivateLinkService, keyed by its id.
class PrivateLinkServiceAwsResource < Sequel::Model
  many_to_one :private_link_service, key: :id, read_only: true
  one_to_many :allowed_endpoints, class: :PrivateLinkServiceAwsAllowedEndpoint, order: :vpc_endpoint_id

  plugin :association_dependencies, allowed_endpoints: :destroy
  plugin ResourceMethods, referencing: UBID::TYPE_PRIVATE_LINK_SERVICE

  # The standard partition's regions as the SDK knows them, opt-in ones
  # included; the account's opt-ins are checked when a form is submitted.
  SUPPORTED_REGIONS = Aws::Partitions.partition("aws").regions.map(&:name).grep(/\A[a-z]+-[a-z]+-\d+\z/).sort.freeze

  # Clover code cannot read model constants (helpers/model_hiding.rb), so the
  # create and settings forms go through this allowlisted class method.
  def self.supported_regions
    SUPPORTED_REGIONS
  end

  PRIVATE_DNS_VERIFICATION_INTERVAL = 30 * 60

  def private_dns_verified?
    private_dns_verification_state == "verified"
  end

  def private_dns_verification_due?(now = Time.now)
    return false if private_link_service.private_dns_name.nil? || private_dns_verified?

    private_dns_verification_attempted_at.nil? || private_dns_verification_attempted_at < now - PRIVATE_DNS_VERIFICATION_INTERVAL
  end

  def forget_private_dns_verification
    update(private_dns_verification_attempted_at: nil)
  end

  def private_dns_verification_record_name
    return unless private_dns_verification_name && (domain = private_link_service.private_dns_domain)

    "#{private_dns_verification_name}.#{domain}"
  end

  # The service's own region is always supported and never stored.
  def update_supported_regions(regions)
    update(supported_regions: Sequel.pg_array((regions - [private_link_service.location.name]).uniq.sort, :text))
    private_link_service.incr_reconcile
  end

  def update_allowed_endpoints(entries)
    DB.transaction do
      # The rows carry nothing worth archiving, so skip the destroy hooks.
      allowed_endpoints_dataset.delete(force: true)
      rows = entries.map { |vpc_endpoint_id, description| {private_link_service_aws_resource_id: id, vpc_endpoint_id:, description:} }
      PrivateLinkServiceAwsAllowedEndpoint.multi_insert(rows) unless rows.empty?
      associations.delete(:allowed_endpoints)
      private_link_service.incr_reconcile_connections
    end
  end
end

# Table: private_link_service_aws_resource
# Columns:
#  id                                    | uuid                     | PRIMARY KEY
#  nlb_arn                               | text                     |
#  service_id                            | text                     |
#  service_name                          | text                     |
#  supported_regions                     | text[]                   | NOT NULL DEFAULT '{}'::text[]
#  registered_target_ips                 | inet[]                   | NOT NULL DEFAULT '{}'::inet[]
#  private_dns_verification_state        | text                     |
#  private_dns_verification_name         | text                     |
#  private_dns_verification_value        | text                     |
#  private_dns_verification_attempted_at | timestamp with time zone |
#  private_dns_txt_record_name           | text                     |
# Indexes:
#  private_link_service_aws_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  private_link_service_aws_resource_id_fkey | (id) REFERENCES private_link_service(id) ON DELETE CASCADE
# Referenced By:
#  private_link_service_aws_allowed_endpoint | private_link_service_aws_allo_private_link_service_aws_res_fkey | (private_link_service_aws_resource_id) REFERENCES private_link_service_aws_resource(id) ON DELETE CASCADE
