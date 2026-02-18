# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0ec7057ec5fad7e47", "ami-0921aa8d0d9e87eb9"],
    ["us-east-1", "x64", "ami-046ea18f748f0b14a", "ami-0964c462716607d90"],
    ["us-east-2", "x64", "ami-01d90da2797cd161c", "ami-052a6ec9973ee9196"],
    ["eu-west-1", "x64", "ami-06b8099588ba2fbbf", "ami-0370e12352f15902e"],
    ["ap-southeast-2", "x64", "ami-02863dc84159f6ff5", "ami-0714b0e80026f0700"],
    ["us-west-2", "arm64", "ami-0d34af69c6e816e93", "ami-029d46a417cbbb2d3"],
    ["us-east-1", "arm64", "ami-075dd67ffd7ea12a1", "ami-09b9c68e0e535256b"],
    ["us-east-2", "arm64", "ami-057b0bf5bf0af62d4", "ami-0b5225540951bd764"],
    ["eu-west-1", "arm64", "ami-0b62a8210720b7e39", "ami-060cb6bfd8643a124"],
    ["ap-southeast-2", "arm64", "ami-079943061900fc0e1", "ami-0dbc06390bc9509f9"]
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
