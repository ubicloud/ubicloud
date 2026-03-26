# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0063bf3b059d94eb5", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-06a8ed4630b28ff70", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-009dcd39d66d8b07c", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-0cccd456705c9b736", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-0278e268fc5eb50ff", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-01306811894d6f5b6", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-0ad5c7d866757ede8", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-0f87a3a01c848584e", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-09e7237d6a8df5703", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-0e04b8b79c846fb97", "ami-00e1a84392ef33cd7"]
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
