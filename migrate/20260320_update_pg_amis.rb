# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0fac9c2827ce3c000", "ami-0ec7057ec5fad7e47"],
    ["us-east-1", "x64", "ami-05dee0aaf90ceb7bb", "ami-046ea18f748f0b14a"],
    ["us-east-2", "x64", "ami-0e33685f5791249a6", "ami-01d90da2797cd161c"],
    ["eu-west-1", "x64", "ami-0d2e189824fc84962", "ami-06b8099588ba2fbbf"],
    ["ap-southeast-2", "x64", "ami-0d193b949a193ae6d", "ami-02863dc84159f6ff5"],
    ["us-west-2", "arm64", "ami-08a7683b9d8320467", "ami-0d34af69c6e816e93"],
    ["us-east-1", "arm64", "ami-0b722396852594d29", "ami-075dd67ffd7ea12a1"],
    ["us-east-2", "arm64", "ami-023f659e207267d53", "ami-057b0bf5bf0af62d4"],
    ["eu-west-1", "arm64", "ami-0df52e39fac168dc2", "ami-0b62a8210720b7e39"],
    ["ap-southeast-2", "arm64", "ami-00e1a84392ef33cd7", "ami-079943061900fc0e1"],
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
