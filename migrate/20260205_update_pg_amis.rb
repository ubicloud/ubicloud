# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0765f71bf0d92f856", "ami-084600c250269044d"],
    ["us-east-1", "x64", "ami-039c50c95d706deb0", "ami-096c2c2c73d94b700"],
    ["us-east-2", "x64", "ami-0b86bac7ad7028632", "ami-0841a3a2703abcd47"],
    ["eu-west-1", "x64", "ami-0c034d13972955c2b", "ami-0e38c2ad60fe310ed"],
    ["ap-southeast-2", "x64", "ami-074aa9b0216fe4acd", "ami-0e914bbc89f0cccb2"],
    ["us-west-2", "arm64", "ami-078463c0b09ced281", "ami-0ae0f4a1fb36ba703"],
    ["us-east-1", "arm64", "ami-0030fa71a6726182f", "ami-000d705e37bdd8de1"],
    ["us-east-2", "arm64", "ami-05ad7f9eba8976570", "ami-09ee60ae7acd69303"],
    ["eu-west-1", "arm64", "ami-06a64b8a346c3c940", "ami-020ee721c0b6f0eb3"],
    ["ap-southeast-2", "arm64", "ami-03065a55a4d88f9a3", "ami-0e0cad9a4ec9bd737"]
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
