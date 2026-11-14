# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-021c5db35b6595aff", "ami-0196cfb1b4fb36f3b"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-0433e85f6d86046ef", "ami-056565447d9564384"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-015ddaea82ddbc5bc", "ami-05a999aabc1b01e45"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-0cfaa0323451053a4", "ami-039e763950bc86c58"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-02fc50ee9e23d6362", "ami-0239b66cd927651ec"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-0429a9b04e5e827bc", "ami-09e503371eb4797b2"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-058f3b0f6af69b8cb", "ami-0034f46bc05c85078"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-0ddc197914c1c3f34", "ami-063c34ee9a7f4dcd7"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-0316ee41f2f7dd0a1", "ami-052687fa7b213aa72"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-02d98ee1832352dbf", "ami-01f8cda0db1cd215e"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-0bc7b60a5fbb1da98", "ami-0ef03ac8593e0d7db"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-0716dd8a2a055701d", "ami-08ed7c98dacf53ba1"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-0f2186ea93f4ab6dd", "ami-0658e3d9870ed1a60"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-007972222d2dd9a25", "ami-0f14db387833d437c"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-0fc5775b54fb8961b", "ami-0df4075af1a2e06b2"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-08933d7a0d903fcc9", "ami-04fb15ce1001572e8"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-0c328f83eda3af759", "ami-02bdea4e94fd8915d"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-07e672cc4e2cf350b", "ami-0e77ae57bf4f70f4a"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-0f0d59f1fc8e287ad", "ami-0ac428849e7576c58"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-0e402d99468fb6f83", "ami-07424e2ac09a1861a"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261114-1-0", "postgres-ubuntu-2604-x64-20261030-1-0"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261114-1-0", "postgres-ubuntu-2604-arm64-20261030-1-0"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261114-1-0", "postgres-ubuntu-2204-x64-20261030-1-0"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261114-1-0", "postgres-ubuntu-2204-arm64-20261030-1-0"],
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
