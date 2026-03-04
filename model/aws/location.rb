# frozen_string_literal: true

class Location < Sequel::Model
  one_to_many :location_aws_azs, remover: nil, clearer: nil

  module Aws
    def pg_ami(pg_version, arch)
      ami = PgAwsAmi.find(aws_location_name: name, pg_version:, arch:)
      raise "No AMI found for PostgreSQL #{pg_version} (#{arch}) in #{name}" unless ami
      ami.aws_ami_id
    end

    private

    def aws_pg_boot_image(pg_version, arch, flavor)
      pg_ami(pg_version, arch)
    end

    def aws_azs
      v = location_aws_azs_dataset.all
      return v unless v.empty?
      set_aws_azs
    end

    def set_aws_azs
      get_azs_from_aws.map do |az|
        LocationAwsAz.create(location_id: id, zone_id: az.zone_id, az: az.zone_name.delete_prefix(name))
      end
    end

    def get_azs_from_aws
      location_credential.client.describe_availability_zones.availability_zones
    end
  end
end
