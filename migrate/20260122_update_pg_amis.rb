# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-05e5db2adcb6e7d21", "ami-042161c17b1718547"],
    ["us-east-1", "x64", "ami-05bf5156804e5ef46", "ami-0137b56243210a883"],
    ["us-east-2", "x64", "ami-092b0c8bc8dd815c5", "ami-0e0b1d0e3e926d066"],
    ["eu-west-1", "x64", "ami-063383a712e6bdf43", "ami-0a9ecb1f734e3267e"],
    ["ap-southeast-2", "x64", "ami-0f463ef9397b041a7", "ami-063f4af4439eca1b3"],
    ["us-west-2", "arm64", "ami-0e5987ce8c99885f2", "ami-0bcf0974e0dfd19b7"],
    ["us-east-1", "arm64", "ami-027b51d703b0618ca", "ami-03f25039f0bd61216"],
    ["us-east-2", "arm64", "ami-04cd6e624604d0ca1", "ami-0298f1dccfb07c6ec"],
    ["eu-west-1", "arm64", "ami-01b913543de91af67", "ami-06d8da668cf964b22"],
    ["ap-southeast-2", "arm64", "ami-08f3a19c3d3af741c", "ami-04179a820c1bd4c82"]
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
