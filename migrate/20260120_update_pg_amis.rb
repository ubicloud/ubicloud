# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-042161c17b1718547", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-0137b56243210a883", "ami-0baca50c6f0398ccb"],
    ["us-east-2", "x64", "ami-0e0b1d0e3e926d066", "ami-0199d6df117801fc7"],
    ["eu-west-1", "x64", "ami-0a9ecb1f734e3267e", "ami-04e410455af2701a7"],
    ["ap-southeast-2", "x64", "ami-063f4af4439eca1b3", "ami-058daa4601bf9bb85"],
    ["us-west-2", "arm64", "ami-0bcf0974e0dfd19b7", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-03f25039f0bd61216", "ami-0ec032eb86708362d"],
    ["us-east-2", "arm64", "ami-0298f1dccfb07c6ec", "ami-065754213f20865f4"],
    ["eu-west-1", "arm64", "ami-06d8da668cf964b22", "ami-0381f44b045b93d25"],
    ["ap-southeast-2", "arm64", "ami-04179a820c1bd4c82", "ami-03380543da666e424"]
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
