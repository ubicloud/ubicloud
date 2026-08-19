# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0f9e2b0c5348e7a4c", "ami-010d53641c2b9287f"],
    ["us-east-1", "x64", "ami-08eecaec97fc4f8c9", "ami-0bd811e319dc2ce2b"],
    ["us-east-2", "x64", "ami-01ad30a191cd415a0", "ami-0230a90cc05e8f698"],
    ["eu-west-1", "x64", "ami-0e341845c7b9b248e", "ami-0f603cb43d36474a1"],
    ["ap-southeast-2", "x64", "ami-06ffe4c907cf53425", "ami-0731d3f2300f73606"],
    ["us-west-2", "arm64", "ami-0fc1357a6014441a3", "ami-06d37081edad11ea9"],
    ["us-east-1", "arm64", "ami-0bbd353cc617bc1f9", "ami-0de73865a0fc5c394"],
    ["us-east-2", "arm64", "ami-0680cb0a2c8bff803", "ami-0003652cecea35f39"],
    ["eu-west-1", "arm64", "ami-0fe5ecbca4542a40f", "ami-0fd7bfa51c7be900d"],
    ["ap-southeast-2", "arm64", "ami-03ed2e3d7d4055888", "ami-0df89d755109831aa"],
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
