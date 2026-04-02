# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0dcb035b2285d4501", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-04496734dccdb02fa", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-08d8b14cdffd8228d", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-0fe22863846759d02", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-070f74588fae89b0c", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-0b91ab5030f3d0835", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-055fe31b8b0c3afc4", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-0b3dd9f455bfec105", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-0101a75097fd403fd", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-049c555296f4747bd", "ami-00e1a84392ef33cd7"]
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
