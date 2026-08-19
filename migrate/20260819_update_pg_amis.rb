# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0cbace51caabec97a", "ami-010d53641c2b9287f"],
    ["us-east-1", "x64", "ami-04a7a887f111b1f0f", "ami-0bd811e319dc2ce2b"],
    ["us-east-2", "x64", "ami-06a192dfd1dc56729", "ami-0230a90cc05e8f698"],
    ["eu-west-1", "x64", "ami-0a51fcd2701a000e7", "ami-0f603cb43d36474a1"],
    ["ap-southeast-2", "x64", "ami-0b01616cb86235e89", "ami-0731d3f2300f73606"],
    ["us-west-2", "arm64", "ami-03b31c4be58330dee", "ami-06d37081edad11ea9"],
    ["us-east-1", "arm64", "ami-01ebe8b84117a11d5", "ami-0de73865a0fc5c394"],
    ["us-east-2", "arm64", "ami-0a54050720be6dae5", "ami-0003652cecea35f39"],
    ["eu-west-1", "arm64", "ami-0079ed1fa774ef229", "ami-0fd7bfa51c7be900d"],
    ["ap-southeast-2", "arm64", "ami-0725176a44c8385af", "ami-0df89d755109831aa"],
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
