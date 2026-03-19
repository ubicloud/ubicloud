# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-01f7840049eb2e5af", "ami-0ec7057ec5fad7e47"],
    ["us-east-1", "x64", "ami-0c6987f020fa67987", "ami-046ea18f748f0b14a"],
    ["us-east-2", "x64", "ami-0f421c5f7e01cd131", "ami-01d90da2797cd161c"],
    ["eu-west-1", "x64", "ami-078b84f286dce69cf", "ami-06b8099588ba2fbbf"],
    ["ap-southeast-2", "x64", "ami-013291c0e3a5e330b", "ami-02863dc84159f6ff5"],
    ["us-west-2", "arm64", "ami-07a1d747d8cdedda8", "ami-0d34af69c6e816e93"],
    ["us-east-1", "arm64", "ami-0b6916c061d067436", "ami-075dd67ffd7ea12a1"],
    ["us-east-2", "arm64", "ami-0aad63561013ba18c", "ami-057b0bf5bf0af62d4"],
    ["eu-west-1", "arm64", "ami-0706f2b0f56711ad2", "ami-0b62a8210720b7e39"],
    ["ap-southeast-2", "arm64", "ami-0d06d9f1081e0f62f", "ami-079943061900fc0e1"]
  ]

  up do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
    end
  end

  down do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
    end
  end
end
