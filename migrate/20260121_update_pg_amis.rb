# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-046f45dc0d772e7d5", "ami-042161c17b1718547"],
    ["us-east-1", "x64", "ami-0d0207026fb54d910", "ami-0137b56243210a883"],
    ["us-east-2", "x64", "ami-05176030306670c54", "ami-0e0b1d0e3e926d066"],
    ["eu-west-1", "x64", "ami-0cc18674f585db9fd", "ami-0a9ecb1f734e3267e"],
    ["ap-southeast-2", "x64", "ami-08e2ef3184ebd22a8", "ami-063f4af4439eca1b3"],
    ["us-west-2", "arm64", "ami-05bf5515fdd290b26", "ami-0bcf0974e0dfd19b7"],
    ["us-east-1", "arm64", "ami-0eda52293e86c7f32", "ami-03f25039f0bd61216"],
    ["us-east-2", "arm64", "ami-04a2dfa0ae839d2d1", "ami-0298f1dccfb07c6ec"],
    ["eu-west-1", "arm64", "ami-058e7492417f8654a", "ami-06d8da668cf964b22"],
    ["ap-southeast-2", "arm64", "ami-01f29e80e1e679a66", "ami-04179a820c1bd4c82"]
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
