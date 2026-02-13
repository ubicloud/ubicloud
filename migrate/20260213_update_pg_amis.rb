# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0643653705d03da11", "ami-0765f71bf0d92f856"],
    ["us-east-1", "x64", "ami-08bb3d01832f5608c", "ami-039c50c95d706deb0"],
    ["us-east-2", "x64", "ami-0030ffca00ab62a0a", "ami-0b86bac7ad7028632"],
    ["eu-west-1", "x64", "ami-033b508730f8fdca5", "ami-0c034d13972955c2b"],
    ["ap-southeast-2", "x64", "ami-0f785e228cd0fb5d5", "ami-074aa9b0216fe4acd"],
    ["us-west-2", "arm64", "ami-08ae3eeeaaa6f1b20", "ami-078463c0b09ced281"],
    ["us-east-1", "arm64", "ami-0df2b08ca8033f290", "ami-0030fa71a6726182f"],
    ["us-east-2", "arm64", "ami-0b5c6e9c9f85af1d7", "ami-05ad7f9eba8976570"],
    ["eu-west-1", "arm64", "ami-02f17dc06f680fedd", "ami-06a64b8a346c3c940"],
    ["ap-southeast-2", "arm64", "ami-004359cc3bf27e877", "ami-03065a55a4d88f9a3"]
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
