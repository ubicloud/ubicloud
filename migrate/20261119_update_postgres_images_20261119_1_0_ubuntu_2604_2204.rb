# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-05cf700e95ed62020", "ami-05eb4d1e21c54afc0"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-02d319ae81e1f47cb", "ami-0aa2db097d4d5c01f"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-0bd00e5482d3614e2", "ami-01d81fa46a4cb8677"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-08d0d5154bb7cf7e3", "ami-083d99f9d15f2efa3"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-0a36c726fa31828e2", "ami-04f98554dd4b274f9"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-0e679f86567daa311", "ami-048269555e5a8f8a6"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-03062d7f6e8571416", "ami-005bed9ac4985991a"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-0d369800a7a7dee12", "ami-09cb61e75a2b511d4"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-05ce20f2eeb24a0c0", "ami-049e9b43ef3c673b2"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-05f1c2c3da043dff1", "ami-073f092d5bc0ac552"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-0bb3683eaec5c4ae3", "ami-006ec4c8442437e01"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-00e841450a698f204", "ami-0a25d6fee581f4e45"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-0f4b33e13aaefa762", "ami-0a8f7c98c450e6acf"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-087bebf1e8b3aa490", "ami-044372dc660fa0654"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-0d733e23ca95c515e", "ami-0a936b98cf3e0d3c8"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-0a4922fbaa6c2c56e", "ami-0fa3ccb3d9995fc05"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-03c9059239a62b927", "ami-03e150fa614980cd9"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-030435cd0975bc3c8", "ami-0419062cebeb3f468"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-0754711dcda010557", "ami-0b98dcac358f3214b"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-07d1c52bfcaf00a1e", "ami-04932ba28dd5eea1c"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261119-1-0", "postgres-ubuntu-2604-x64-20261115-1-2"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261119-1-0", "postgres-ubuntu-2604-arm64-20261115-1-2"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261119-1-0", "postgres-ubuntu-2204-x64-20261115-1-2"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261119-1-0", "postgres-ubuntu-2204-arm64-20261115-1-2"],
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
