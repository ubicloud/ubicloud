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
  end
end
