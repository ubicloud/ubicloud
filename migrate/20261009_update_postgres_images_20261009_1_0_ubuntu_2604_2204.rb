# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-0cbbfc7b447ff89c1", "ami-0815814def04d3d8c"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-09954b47182709f68", "ami-054b8becc7380af60"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-02d75f1e8df5bc584", "ami-05635fb4e2f408cad"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-06d46dbff07b7811b", "ami-05fdacd5b39626797"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-096d7dde27a8f6550", "ami-03b5b6e8a959ae84f"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-01ad33b1795e1d145", "ami-01d016753204a1140"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-0b934c4a1381c753f", "ami-0b86f25a535f175e7"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-0cca8b95eacc9b631", "ami-0e6db7c30e9e75ff6"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-092d6213da74eb976", "ami-0c42d87bbffe61a0a"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-0afd0b2e67e409019", "ami-0b39bc479b4a6d69a"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-07bf5c9ba23dba79e", "ami-0b7bdb042b3955f99"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-0b55b1de22dee13c6", "ami-084b7943885b1cef7"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-0c41710f523208843", "ami-0b63e7b99939c4acd"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-089cb4eb94e6aaa5a", "ami-095439c961ad757a0"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-0c1d266986961338a", "ami-023988ab93a83b4f9"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-06769414615cb1d72", "ami-0152ae2606f51e3b3"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-0d327bd5ab345f478", "ami-0402b7678d954e68c"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-0df78e2336e14d802", "ami-01dba5966e5ef456b"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-0bb752cf04077109c", "ami-0a525387eb555441c"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-0f4a83787dbb50f6e", "ami-0649a520a5ef03f0c"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261009-1-0", "postgres-ubuntu-2604-x64-20261007-1-0"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261009-1-0", "postgres-ubuntu-2604-arm64-20261007-1-0"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261009-1-0", "postgres-ubuntu-2204-x64-20261007-1-0"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261009-1-0", "postgres-ubuntu-2204-arm64-20261007-1-0"],
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
