# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-002d8a898102f6fe3", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-0b4cf02808395b205", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-0ad2194284dcb110a", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-02fedae2e097ad3f4", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-06fb2450aabc62e04", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-0c8c23baa03e11471", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-0e8564bc98f0cc130", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-076281335368620ff", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-054ea1d7582c73980", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-0cc3208ebcd14d250", "ami-00e1a84392ef33cd7"],
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
