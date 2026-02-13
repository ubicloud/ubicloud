# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-09a108088052a6946", "ami-0765f71bf0d92f856"],
    ["us-east-1", "x64", "ami-03f178375c568ebeb", "ami-039c50c95d706deb0"],
    ["us-east-2", "x64", "ami-0492d30e84e4b5bc5", "ami-0b86bac7ad7028632"],
    ["eu-west-1", "x64", "ami-0fd3b34de6226b979", "ami-0c034d13972955c2b"],
    ["ap-southeast-2", "x64", "ami-0ee79cd73c673dc38", "ami-074aa9b0216fe4acd"]
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
