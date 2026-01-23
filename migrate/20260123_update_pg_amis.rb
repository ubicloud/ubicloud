# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-06117c26f617d438b", "ami-042161c17b1718547"],
    ["us-east-1", "x64", "ami-0a9e2c6f27818523d", "ami-0137b56243210a883"],
    ["us-east-2", "x64", "ami-0a86960ab2d36682c", "ami-0e0b1d0e3e926d066"],
    ["eu-west-1", "x64", "ami-000848dcac93911f7", "ami-0a9ecb1f734e3267e"],
    ["ap-southeast-2", "x64", "ami-04da6741347527e45", "ami-063f4af4439eca1b3"]
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
