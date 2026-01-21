# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-080a91c790364e992", "ami-042161c17b1718547"],
    ["us-east-1", "x64", "ami-046aa2a05911a6adc", "ami-0137b56243210a883"],
    ["us-east-2", "x64", "ami-03b9af37ec8abf7ff", "ami-0e0b1d0e3e926d066"],
    ["eu-west-1", "x64", "ami-0883c81cd410e8768", "ami-0a9ecb1f734e3267e"],
    ["ap-southeast-2", "x64", "ami-08b10ff745c53b70d", "ami-063f4af4439eca1b3"],
    ["us-west-2", "arm64", "ami-0ca665b8f798924eb", "ami-0bcf0974e0dfd19b7"],
    ["us-east-1", "arm64", "ami-0a618bb430ffe424f", "ami-03f25039f0bd61216"],
    ["us-east-2", "arm64", "ami-07f46e32803862eb5", "ami-0298f1dccfb07c6ec"],
    ["eu-west-1", "arm64", "ami-0d53ebea1ef993ea9", "ami-06d8da668cf964b22"],
    ["ap-southeast-2", "arm64", "ami-0a3790ed86565d17f", "ami-04179a820c1bd4c82"]
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
