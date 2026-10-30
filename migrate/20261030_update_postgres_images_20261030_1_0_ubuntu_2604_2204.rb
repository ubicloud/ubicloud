# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-0196cfb1b4fb36f3b", "ami-0cbbfc7b447ff89c1"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-056565447d9564384", "ami-09954b47182709f68"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-05a999aabc1b01e45", "ami-02d75f1e8df5bc584"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-039e763950bc86c58", "ami-06d46dbff07b7811b"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-0239b66cd927651ec", "ami-096d7dde27a8f6550"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-09e503371eb4797b2", "ami-01ad33b1795e1d145"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-0034f46bc05c85078", "ami-0b934c4a1381c753f"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-063c34ee9a7f4dcd7", "ami-0cca8b95eacc9b631"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-052687fa7b213aa72", "ami-092d6213da74eb976"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-01f8cda0db1cd215e", "ami-0afd0b2e67e409019"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-0ef03ac8593e0d7db", "ami-07bf5c9ba23dba79e"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-08ed7c98dacf53ba1", "ami-0b55b1de22dee13c6"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-0658e3d9870ed1a60", "ami-0c41710f523208843"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-0f14db387833d437c", "ami-089cb4eb94e6aaa5a"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-0df4075af1a2e06b2", "ami-0c1d266986961338a"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-04fb15ce1001572e8", "ami-06769414615cb1d72"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-02bdea4e94fd8915d", "ami-0d327bd5ab345f478"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-0e77ae57bf4f70f4a", "ami-0df78e2336e14d802"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-0ac428849e7576c58", "ami-0bb752cf04077109c"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-07424e2ac09a1861a", "ami-0f4a83787dbb50f6e"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261030-1-0", "postgres-ubuntu-2604-x64-20261009-1-0"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261030-1-0", "postgres-ubuntu-2604-arm64-20261009-1-0"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261030-1-0", "postgres-ubuntu-2204-x64-20261009-1-0"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261030-1-0", "postgres-ubuntu-2204-arm64-20261009-1-0"],
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
