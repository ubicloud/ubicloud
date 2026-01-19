# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-06aa86d70966bdbbf", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-0f9778bbc357529f6", "ami-0baca50c6f0398ccb"],
    ["us-east-2", "x64", "ami-0d8d83ad3eb2ab0dc", "ami-0199d6df117801fc7"],
    ["eu-west-1", "x64", "ami-0a3ea2dc79aee9647", "ami-04e410455af2701a7"],
    ["ap-southeast-2", "x64", "ami-04d6d19114e422742", "ami-058daa4601bf9bb85"],
    ["us-west-2", "arm64", "ami-09593796fcce26e15", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-088ce7fe1fb3b1426", "ami-0ec032eb86708362d"],
    ["us-east-2", "arm64", "ami-0fcb61f7f73dc069a", "ami-065754213f20865f4"],
    ["eu-west-1", "arm64", "ami-00ae9cf7f65fa6ea9", "ami-0381f44b045b93d25"],
    ["ap-southeast-2", "arm64", "ami-0cce501add55f7554", "ami-03380543da666e424"]
  ]

  up do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch: arch, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
    end
  end

  down do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch: arch, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
    end
  end
end
