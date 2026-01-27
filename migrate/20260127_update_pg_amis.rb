# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-084600c250269044d", "ami-0648b09582126019c"],
    ["us-east-1", "x64", "ami-096c2c2c73d94b700", "ami-00721d2bcb72bc798"],
    ["us-east-2", "x64", "ami-0841a3a2703abcd47", "ami-02194ea0f45d9ad90"],
    ["eu-west-1", "x64", "ami-0e38c2ad60fe310ed", "ami-08f3f94032b404ac8"],
    ["ap-southeast-2", "x64", "ami-0e914bbc89f0cccb2", "ami-0143ebba55241a7bb"],
    ["us-west-2", "arm64", "ami-0ae0f4a1fb36ba703", "ami-0a2efc7ae2dad69c8"],
    ["us-east-1", "arm64", "ami-000d705e37bdd8de1", "ami-0da22fbdd571c9bac"],
    ["us-east-2", "arm64", "ami-09ee60ae7acd69303", "ami-0d42e3872e22a6a73"],
    ["eu-west-1", "arm64", "ami-020ee721c0b6f0eb3", "ami-0cf26a35275aaf530"],
    ["ap-southeast-2", "arm64", "ami-0e0cad9a4ec9bd737", "ami-082aaa8eb267e01b3"]
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
