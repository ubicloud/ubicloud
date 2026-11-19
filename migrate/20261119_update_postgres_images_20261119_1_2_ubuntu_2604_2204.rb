# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-0c2e9d2d9da8230f2", "ami-05eb4d1e21c54afc0"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-0b703634b2177d1a7", "ami-0aa2db097d4d5c01f"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-05dcda90861af75c4", "ami-01d81fa46a4cb8677"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-06389dfacccbc2198", "ami-083d99f9d15f2efa3"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-0bb053beb0b00bfcd", "ami-04f98554dd4b274f9"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-08be172d87a7fb9be", "ami-048269555e5a8f8a6"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-0c6d578f4facac594", "ami-005bed9ac4985991a"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-022047ab14d799c1d", "ami-09cb61e75a2b511d4"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-0e751d226c2633f19", "ami-049e9b43ef3c673b2"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-0f0ff4f70ebf9ce0f", "ami-073f092d5bc0ac552"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-004e19e3e401b2d96", "ami-006ec4c8442437e01"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-069aba4bc7216b3f4", "ami-0a25d6fee581f4e45"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-0b749e9e3c5f97c59", "ami-0a8f7c98c450e6acf"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-095c13bd07a885878", "ami-044372dc660fa0654"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-04453a37706cd7880", "ami-0a936b98cf3e0d3c8"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-092940b050b43c5b0", "ami-0fa3ccb3d9995fc05"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-051b5b1265d893364", "ami-03e150fa614980cd9"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-0a1cdc7e4b494838f", "ami-0419062cebeb3f468"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-05730b1b01e1932b4", "ami-0b98dcac358f3214b"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-0ba18ed499af36a6d", "ami-04932ba28dd5eea1c"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261119-1-2", "postgres-ubuntu-2604-x64-20261115-1-2"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261119-1-2", "postgres-ubuntu-2604-arm64-20261115-1-2"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261119-1-2", "postgres-ubuntu-2204-x64-20261115-1-2"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261119-1-2", "postgres-ubuntu-2204-arm64-20261115-1-2"],
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
