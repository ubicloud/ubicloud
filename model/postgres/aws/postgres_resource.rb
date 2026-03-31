# frozen_string_literal: true

class PostgresResource < Sequel::Model
  module Aws
    def self.available_families_and_sizes(location)
      Set.new(
        OptionTreeFilter.filter(provider: "aws", location: location.name).map { |e| [e[:family], e[:size]] },
      )
    end

    def self.family_allowed?(_location, project, family)
      ["m8gd", "i8g"].include?(family) || (Option::AWS_FAMILY_OPTIONS.include?(family) && project.send(:"get_ff_enable_#{family}"))
    end

    def self.storage_sizes(_location, family, vcpu_count)
      Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpu_count]
    end

    private

    def aws_upgrade_candidate_server
      # TODO: We check if the AWS server is running the latest AMI version tracked in
      # the pg_aws_ami table. We can optimize this to consider more AMIs by tracking
      # the creation times in the pg_aws_ami table.
      servers
        .reject(&:is_representative)
        .select { |server| PgAwsAmi.where(aws_ami_id: server.vm.boot_image).count > 0 }
        .max_by(&:created_at)
    end

    def aws_new_server_exclusion_filters
      exclude_availability_zones, availability_zone = if use_different_az_set?
        # Only exclude AZs of servers that will remain after convergence. Servers
        # that need recycling or are being destroyed will leave their AZ, so it
        # should be available for the replacement.
        active_vm_ids = servers.reject { |s| s.needs_recycling? || s.destroy_set? }.map(&:vm_id)
        subnet_azs = NicAwsResource
          .join(:nic, id: :id)
          .where(vm_id: active_vm_ids)
          .distinct
          .select_map(:subnet_az)

        [subnet_azs, nil]
      else
        [[], representative_server.vm.nic.nic_aws_resource.subnet_az]
      end
      ServerExclusionFilters.new(exclude_host_ids: [], exclude_data_centers: [], exclude_availability_zones:, availability_zone:)
    end
  end
end
