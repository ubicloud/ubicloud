# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0a24e827f641a0383", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-01fa4b609a3ba8831", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-09aefcc9aae0c8f4f", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-00717f5e2eff1e5d7", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-0227972b8dc698fa1", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-0b867e0cff38c3cf9", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-0ba0bdb822b262fe9", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-0764c1cdb6ad8e556", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-0ae6bbe1b4a68e28c", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-0767fec533d09b81b", "ami-00e1a84392ef33cd7"]
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
