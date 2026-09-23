# frozen_string_literal: true

Sequel.migration do
  family = "ubuntu-2604"
  ami_ids = [
    ["us-west-2", "x64", "ami-094c7c01f947448bf", "ami-062a7165614bee18d"],
    ["us-east-1", "x64", "ami-0daa3066647e65d01", "ami-06415424650897391"],
    ["us-east-2", "x64", "ami-085462b468db9b188", "ami-0664bcab58c919dc3"],
    ["eu-west-1", "x64", "ami-053508024d4e0d0da", "ami-08d0f9e8bf24237bf"],
    ["ap-southeast-2", "x64", "ami-0907c159de90d0122", "ami-0893a1e61400a31d5"],
    ["us-west-2", "arm64", "ami-0ea2cc5fd5e55e6af", "ami-07cdeab86a9ae662b"],
    ["us-east-1", "arm64", "ami-08ecc8d90179e52b7", "ami-0f76a3e70a8d7d177"],
    ["us-east-2", "arm64", "ami-0d87343679c5bdbe5", "ami-0e3f3672186e413f9"],
    ["eu-west-1", "arm64", "ami-0f8baa4e151cd4884", "ami-0ebdd569743502bf8"],
    ["ap-southeast-2", "arm64", "ami-08d0717043000607e", "ami-0ca7f39d98b42428e"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2604-x64-20260923-1-0", "postgres-ubuntu-2604-x64-20260824-1-0"],
    ["arm64", "postgres-ubuntu-2604-arm64-20260923-1-0", "postgres-ubuntu-2604-arm64-20260824-1-0"],
  ]

  up do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
    end

    gce_images.each do |arch, new_name, old_name|
      from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: old_name)
        .update(gce_image_name: new_name)
    end
  end

  down do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
    end

    gce_images.each do |arch, new_name, old_name|
      from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: new_name)
        .update(gce_image_name: old_name)
    end
  end
end
