# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-05eb4d1e21c54afc0", "ami-021c5db35b6595aff"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-0aa2db097d4d5c01f", "ami-0433e85f6d86046ef"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-01d81fa46a4cb8677", "ami-015ddaea82ddbc5bc"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-083d99f9d15f2efa3", "ami-0cfaa0323451053a4"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-04f98554dd4b274f9", "ami-02fc50ee9e23d6362"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-048269555e5a8f8a6", "ami-0429a9b04e5e827bc"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-005bed9ac4985991a", "ami-058f3b0f6af69b8cb"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-09cb61e75a2b511d4", "ami-0ddc197914c1c3f34"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-049e9b43ef3c673b2", "ami-0316ee41f2f7dd0a1"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-073f092d5bc0ac552", "ami-02d98ee1832352dbf"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-006ec4c8442437e01", "ami-0bc7b60a5fbb1da98"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-0a25d6fee581f4e45", "ami-0716dd8a2a055701d"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-0a8f7c98c450e6acf", "ami-0f2186ea93f4ab6dd"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-044372dc660fa0654", "ami-007972222d2dd9a25"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-0a936b98cf3e0d3c8", "ami-0fc5775b54fb8961b"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-0fa3ccb3d9995fc05", "ami-08933d7a0d903fcc9"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-03e150fa614980cd9", "ami-0c328f83eda3af759"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-0419062cebeb3f468", "ami-07e672cc4e2cf350b"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-0b98dcac358f3214b", "ami-0f0d59f1fc8e287ad"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-04932ba28dd5eea1c", "ami-0e402d99468fb6f83"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261115-1-2", "postgres-ubuntu-2604-x64-20261114-1-0"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261115-1-2", "postgres-ubuntu-2604-arm64-20261114-1-0"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261115-1-2", "postgres-ubuntu-2204-x64-20261114-1-0"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261115-1-2", "postgres-ubuntu-2204-arm64-20261114-1-0"],
  ]

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
