# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-test-x64-uswest2", "ami-01ac1a090f1a005e2"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-test-x64-useast1", "ami-06754e1d4ab61fee8"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-test-arm64-uswest2", "ami-0dd90e09836d287ce"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-test-arm64-useast1", "ami-08afb69d3fec1a5b2"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-test-x64-uswest2", "ami-01479537cdf946537"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-test-x64-useast1", "ami-0321fd48c36be572a"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-test-arm64-uswest2", "ami-0b4248a52e2a79a99"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-test-arm64-useast1", "ami-0b5a1c19101f4105e"],
  ]
  gce_images = []

  up do
    ami_ids.each do |family, location_name, arch, new_ami, old_ami|
      next if old_ami.empty?
      count = from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
      raise Sequel::Error, "pg_aws_ami: no #{family} row for #{location_name}/#{arch} at #{old_ami}" if count.zero?
    end

    gce_images.each do |family, arch, new_name, old_name|
      count = from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: old_name)
        .update(gce_image_name: new_name)
      raise Sequel::Error, "pg_gce_image: expected 1 #{family} row for #{arch} at #{old_name}, updated #{count}" unless count == 1
    end
  end

  down do
    ami_ids.each do |family, location_name, arch, new_ami, old_ami|
      next if old_ami.empty?
      count = from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
      raise Sequel::Error, "pg_aws_ami: no #{family} row for #{location_name}/#{arch} at #{new_ami}" if count.zero?
    end

    gce_images.each do |family, arch, new_name, old_name|
      count = from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: new_name)
        .update(gce_image_name: old_name)
      raise Sequel::Error, "pg_gce_image: expected 1 #{family} row for #{arch} at #{new_name}, updated #{count}" unless count == 1
    end
  end
end
