# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-022ac113b5f22b2c2", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-0bc62be1b75cf5910", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-0c96600ebd30f4f9f", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-00968ba068eba5a23", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-05c3d14b2d93ee810", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-01f4e1d9d91166335", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-07b5ee7bf00c63369", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-09e8609188a645a64", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-0ebaa42b0a03c7002", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-01ed388fe9ba0f51f", "ami-00e1a84392ef33cd7"],
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
