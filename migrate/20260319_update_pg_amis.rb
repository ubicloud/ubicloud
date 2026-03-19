# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0125323df7c96fec7", "ami-0ec7057ec5fad7e47"],
    ["us-east-1", "x64", "ami-017704f7f2c78e223", "ami-046ea18f748f0b14a"],
    ["us-east-2", "x64", "ami-0608478964ffd9a4a", "ami-01d90da2797cd161c"],
    ["eu-west-1", "x64", "ami-01dad7228c73d1636", "ami-06b8099588ba2fbbf"],
    ["ap-southeast-2", "x64", "ami-06405788df7045760", "ami-02863dc84159f6ff5"],
    ["us-west-2", "arm64", "ami-038ee46bbf59f9f35", "ami-0d34af69c6e816e93"],
    ["us-east-1", "arm64", "ami-0829b7d3b07ee6a1a", "ami-075dd67ffd7ea12a1"],
    ["us-east-2", "arm64", "ami-0309428b3a5309e7f", "ami-057b0bf5bf0af62d4"],
    ["eu-west-1", "arm64", "ami-0c60dd4b32d81ab78", "ami-0b62a8210720b7e39"],
    ["ap-southeast-2", "arm64", "ami-093edf5ec5ac9e118", "ami-079943061900fc0e1"]
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
