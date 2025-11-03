# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    # location_name, arch, new_ami_id, old_ami_id
    ["us-west-2", "x64", "ami-0152e4e0e64ead69e", "ami-0090a7d48d9b50181"],
    ["us-east-1", "x64", "ami-0a3297ad5c0f9f98f", "ami-0631c83abb0823706"],
    ["us-east-2", "x64", "ami-02d0ef7e8ed41ca48", "ami-0ba56319c75bf49eb"],
    ["eu-west-1", "x64", "ami-053e00ece07d06969", "ami-09bd55bf95d7d1192"],
    ["ap-southeast-2", "x64", "ami-0673fbc45098ff3d0", "ami-0aaf00dda04ba4a26"],
    ["us-west-2", "arm64", "ami-0c6359b488a9ed529", "ami-01f9b35cfc74cc771"],
    ["us-east-1", "arm64", "ami-0bb80e22adc550c26", "ami-0baa492ac58de86cd"],
    ["us-east-2", "arm64", "ami-04226de158be1d778", "ami-0c79ded8114765259"],
    ["eu-west-1", "arm64", "ami-0de6479c53ebf2f2a", "ami-0371bfa81d8cbbc16"],
    ["ap-southeast-2", "arm64", "ami-0235e4fbf92c90b06", "ami-0035250352cebef6e"]
  ]
  up do
    ami_ids.each do |location_name, arch, new_ami_id, _|
      run "UPDATE pg_aws_ami SET aws_ami_id = '#{new_ami_id}' WHERE aws_location_name = '#{location_name}' AND arch = '#{arch}'"
    end
  end

  down do
    ami_ids.each do |location_name, arch, _, old_ami_id|
      run "UPDATE pg_aws_ami SET aws_ami_id = '#{old_ami_id}' WHERE aws_location_name = '#{location_name}' AND arch = '#{arch}'"
    end
  end
end
