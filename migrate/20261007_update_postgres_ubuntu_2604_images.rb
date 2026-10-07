# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  family = "ubuntu-2604"

  ami_ids = [
    ["us-west-2", "x64", "ami-0815814def04d3d8c", "ami-01ac1a090f1a005e2"],
    ["us-east-1", "x64", "ami-054b8becc7380af60", "ami-06754e1d4ab61fee8"],
    ["us-east-2", "x64", "ami-05635fb4e2f408cad", "ami-09a7b3f26018143fc"],
    ["eu-west-1", "x64", "ami-05fdacd5b39626797", "ami-000a4426c4fe2d948"],
    ["ap-southeast-2", "x64", "ami-03b5b6e8a959ae84f", "ami-05d55c18d17c05f8a"],
    ["us-west-2", "arm64", "ami-01d016753204a1140", "ami-0dd90e09836d287ce"],
    ["us-east-1", "arm64", "ami-0b86f25a535f175e7", "ami-08afb69d3fec1a5b2"],
    ["us-east-2", "arm64", "ami-0e6db7c30e9e75ff6", "ami-081833297be92a277"],
    ["eu-west-1", "arm64", "ami-0c42d87bbffe61a0a", "ami-0749fe3c2ffcfd3d1"],
    ["ap-southeast-2", "arm64", "ami-0b39bc479b4a6d69a", "ami-0e0d0a622bbec7593"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2604-x64-20261007-1-0", "postgres-ubuntu-2604-x64-20260928-1-0"],
    ["arm64", "postgres-ubuntu-2604-arm64-20261007-1-0", "postgres-ubuntu-2604-arm64-20260928-1-0"],
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
