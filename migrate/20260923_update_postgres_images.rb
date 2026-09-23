# frozen_string_literal: true

Sequel.migration do
  family = "ubuntu-2204"
  ami_ids = [
    ["us-west-2", "x64", "ami-01479537cdf946537", "ami-0f13fab80fee0e3e7"],
    ["us-east-1", "x64", "ami-0321fd48c36be572a", "ami-079fe21ebb641869c"],
    ["us-east-2", "x64", "ami-070a5b10643c750cd", "ami-0fce462d3c8b2d007"],
    ["eu-west-1", "x64", "ami-0c4c78dd08e6f856e", "ami-0ff7d1f28cbed774c"],
    ["ap-southeast-2", "x64", "ami-0045276606bf2d64e", "ami-0effc52e3be7beb63"],
    ["us-west-2", "arm64", "ami-0b4248a52e2a79a99", "ami-00551ed9239c69c3b"],
    ["us-east-1", "arm64", "ami-0b5a1c19101f4105e", "ami-048d50a462b4ca06d"],
    ["us-east-2", "arm64", "ami-0a238e61f1fea71fa", "ami-06fdfb0c450ef4b93"],
    ["eu-west-1", "arm64", "ami-026dd678a2e6aa837", "ami-06b3cb3af9b5944a5"],
    ["ap-southeast-2", "arm64", "ami-092d73395f56ec78d", "ami-09fa06e02140ea66e"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260923-1-0", "postgres-ubuntu-2204-x64-20260904-1-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260923-1-0", "postgres-ubuntu-2204-arm64-20260904-1-0"],
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
