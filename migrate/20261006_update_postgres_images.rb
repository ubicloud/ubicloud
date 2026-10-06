# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  family = "ubuntu-2604"

  ami_ids = [
    ["us-west-2", "x64", "ami-0864cfbf60a90b9b5", "ami-01ac1a090f1a005e2"],
    ["us-east-1", "x64", "ami-0e79ca92e3e93242e", "ami-06754e1d4ab61fee8"],
    ["us-east-2", "x64", "ami-0173e38a20a38f842", "ami-09a7b3f26018143fc"],
    ["eu-west-1", "x64", "ami-015a792c86342863f", "ami-000a4426c4fe2d948"],
    ["ap-southeast-2", "x64", "ami-00553e381543b2c17", "ami-05d55c18d17c05f8a"],
    ["us-west-2", "arm64", "ami-00c2b783491af99bf", "ami-0dd90e09836d287ce"],
    ["us-east-1", "arm64", "ami-0cf430e6edc29ce06", "ami-08afb69d3fec1a5b2"],
    ["us-east-2", "arm64", "ami-039acc3f51e51bd1d", "ami-081833297be92a277"],
    ["eu-west-1", "arm64", "ami-0de5c3947396dae6d", "ami-0749fe3c2ffcfd3d1"],
    ["ap-southeast-2", "arm64", "ami-079aad059b71f75c4", "ami-0e0d0a622bbec7593"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2604-x64-20261006-1-1", "postgres-ubuntu-2604-x64-20260928-1-0"],
    ["arm64", "postgres-ubuntu-2604-arm64-20261006-1-1", "postgres-ubuntu-2604-arm64-20260928-1-0"],
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
