# frozen_string_literal: true

Sequel.migration do
  family = "ubuntu-2604"

  ami_ids = [
    ["us-west-2", "x64", "ami-01ac1a090f1a005e2", "ami-094c7c01f947448bf"],
    ["us-east-1", "x64", "ami-06754e1d4ab61fee8", "ami-0daa3066647e65d01"],
    ["us-east-2", "x64", "ami-09a7b3f26018143fc", "ami-085462b468db9b188"],
    ["eu-west-1", "x64", "ami-000a4426c4fe2d948", "ami-053508024d4e0d0da"],
    ["ap-southeast-2", "x64", "ami-05d55c18d17c05f8a", "ami-0907c159de90d0122"],
    ["us-west-2", "arm64", "ami-0dd90e09836d287ce", "ami-0ea2cc5fd5e55e6af"],
    ["us-east-1", "arm64", "ami-08afb69d3fec1a5b2", "ami-08ecc8d90179e52b7"],
    ["us-east-2", "arm64", "ami-081833297be92a277", "ami-0d87343679c5bdbe5"],
    ["eu-west-1", "arm64", "ami-0749fe3c2ffcfd3d1", "ami-0f8baa4e151cd4884"],
    ["ap-southeast-2", "arm64", "ami-0e0d0a622bbec7593", "ami-08d0717043000607e"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2604-x64-20260928-1-0", "postgres-ubuntu-2604-x64-20260923-1-0"],
    ["arm64", "postgres-ubuntu-2604-arm64-20260928-1-0", "postgres-ubuntu-2604-arm64-20260923-1-0"],
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
