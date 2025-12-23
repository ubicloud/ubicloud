# frozen_string_literal: true

class PostgresResource < Sequel::Model
  module Aws
    private

    def aws_upgrade_candidate_server
      # TODO: We check if the AWS server is running the latest AMI version tracked in
      # the pg_aws_ami table. We can optimize this to consider more AMIs by tracking
      # the creation times in the pg_aws_ami table.
      servers
        .reject(&:representative_at)
        .select { |server| PgAwsAmi.where(aws_ami_id: server.vm.boot_image).count > 0 }
        .max_by(&:created_at)
    end

    # The first element is the list of vm_hosts to exclude from the new server,
    # which is empty for aws servers.
    # The second element is the list of availability zones to exclude from the new server,
    # which is the list of all used availability zones.
    # The third element is the availability zone of the representative server,
    # which is the availability zone of the new server.
    def aws_new_server_exclusion_filters
      exclude_availability_zones, availability_zone = if use_different_az_set?
        subnet_azs = NicAwsResource
          .join(:nic, id: :id)
          .where(vm_id: servers_dataset.select(:vm_id))
          .distinct
          .select_map(:subnet_az)

        [subnet_azs, nil]
      else
        [[], representative_server.vm.nic.nic_aws_resource.subnet_az]
      end
      [[], exclude_availability_zones, availability_zone]
    end
  end
end
