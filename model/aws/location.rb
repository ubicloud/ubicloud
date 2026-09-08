# frozen_string_literal: true

class Location < Sequel::Model
  one_to_many :location_azs, remover: nil, clearer: nil

  module Aws
    # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-instances-status-check_sched.html
    HANDLED_CODES = %w[instance-reboot system-maintenance system-reboot instance-stop instance-retirement].freeze

    def pg_aws_ami(pg_version, arch)
      ami = PgAwsAmi.find(aws_location_name: name, pg_version:, arch:)
      raise "No AMI found for PostgreSQL #{pg_version} (#{arch}) in #{name}" unless ami
      ami.aws_ami_id
    end

    private

    def aws_azs
      v = location_azs_dataset.all
      return v unless v.empty?
      set_aws_azs
    end

    def set_aws_azs
      get_azs_from_aws.map do |az|
        LocationAz.create(location_id: id, zone_id: az.zone_id, az: az.zone_name.delete_prefix(name))
      end
    end

    def get_azs_from_aws
      location_credential_aws.client.describe_availability_zones.availability_zones
    end

    # vm_id => earliest not_before across the instance's pertinent events
    def aws_scheduled_maintenance_events
      # public regions without a credential can't host instances, nothing to scan
      return {} unless (credential = location_credential_aws)
      soonest = {}
      credential.client.describe_instance_status(
        filters: [{name: "event.code", values: HANDLED_CODES}],
      ).each do |page|
        page.instance_statuses.each do |status|
          status.events.each do |event|
            next unless HANDLED_CODES.include?(event.code)
            next if event.description.to_s.start_with?("[Completed]")
            soonest[status.instance_id] = [soonest[status.instance_id], event.not_before].compact.min
          end
        end
      end
      return {} if soonest.empty?

      AwsInstance.where(instance_id: soonest.keys).select_hash(:id, :instance_id).transform_values { soonest[it] }
    end
  end
end
