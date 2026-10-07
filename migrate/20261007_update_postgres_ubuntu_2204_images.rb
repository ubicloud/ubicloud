# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  family = "ubuntu-2204"

  ami_ids = [
    ["us-west-2", "x64", "ami-0b7bdb042b3955f99", "ami-01479537cdf946537"],
    ["us-east-1", "x64", "ami-084b7943885b1cef7", "ami-0321fd48c36be572a"],
    ["us-east-2", "x64", "ami-0b63e7b99939c4acd", "ami-070a5b10643c750cd"],
    ["eu-west-1", "x64", "ami-095439c961ad757a0", "ami-0c4c78dd08e6f856e"],
    ["ap-southeast-2", "x64", "ami-023988ab93a83b4f9", "ami-0045276606bf2d64e"],
    ["us-west-2", "arm64", "ami-0152ae2606f51e3b3", "ami-0b4248a52e2a79a99"],
    ["us-east-1", "arm64", "ami-0402b7678d954e68c", "ami-0b5a1c19101f4105e"],
    ["us-east-2", "arm64", "ami-01dba5966e5ef456b", "ami-0a238e61f1fea71fa"],
    ["eu-west-1", "arm64", "ami-0a525387eb555441c", "ami-026dd678a2e6aa837"],
    ["ap-southeast-2", "arm64", "ami-0649a520a5ef03f0c", "ami-092d73395f56ec78d"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20261007-1-0", "postgres-ubuntu-2204-x64-20260923-1-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20261007-1-0", "postgres-ubuntu-2204-arm64-20260923-1-0"],
  ]

  up do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      next if old_ami.empty?
      count = from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
      raise Sequel::Error, "pg_aws_ami: no #{family} row for #{location_name}/#{arch} at #{old_ami}" if count.zero?
    end

    gce_images.each do |arch, new_name, old_name|
      count = from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: old_name)
        .update(gce_image_name: new_name)
      raise Sequel::Error, "pg_gce_image: expected 1 #{family} row for #{arch} at #{old_name}, updated #{count}" unless count == 1
    end
  end

  down do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      next if old_ami.empty?
      count = from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
      raise Sequel::Error, "pg_aws_ami: no #{family} row for #{location_name}/#{arch} at #{new_ami}" if count.zero?
    end

    gce_images.each do |arch, new_name, old_name|
      count = from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: new_name)
        .update(gce_image_name: old_name)
      raise Sequel::Error, "pg_gce_image: expected 1 #{family} row for #{arch} at #{new_name}, updated #{count}" unless count == 1
    end
  end
end
