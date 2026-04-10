# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-test-x64-uswest2", "ami-022ac113b5f22b2c2"],
    ["us-east-1", "x64", "ami-test-x64-useast1", "ami-0bc62be1b75cf5910"],
    ["us-west-2", "arm64", "ami-test-arm64-uswest2", "ami-01f4e1d9d91166335"],
    ["us-east-1", "arm64", "ami-test-arm64-useast1", "ami-07b5ee7bf00c63369"],
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
