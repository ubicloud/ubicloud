# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0921aa8d0d9e87eb9", "ami-0765f71bf0d92f856"],
    ["us-east-1", "x64", "ami-0964c462716607d90", "ami-039c50c95d706deb0"],
    ["us-east-2", "x64", "ami-052a6ec9973ee9196", "ami-0b86bac7ad7028632"],
    ["eu-west-1", "x64", "ami-0370e12352f15902e", "ami-0c034d13972955c2b"],
    ["ap-southeast-2", "x64", "ami-0714b0e80026f0700", "ami-074aa9b0216fe4acd"],
    ["us-west-2", "arm64", "ami-029d46a417cbbb2d3", "ami-078463c0b09ced281"],
    ["us-east-1", "arm64", "ami-09b9c68e0e535256b", "ami-0030fa71a6726182f"],
    ["us-east-2", "arm64", "ami-0b5225540951bd764", "ami-05ad7f9eba8976570"],
    ["eu-west-1", "arm64", "ami-060cb6bfd8643a124", "ami-06a64b8a346c3c940"],
    ["ap-southeast-2", "arm64", "ami-0dbc06390bc9509f9", "ami-03065a55a4d88f9a3"]
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
