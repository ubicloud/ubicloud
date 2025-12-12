# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    # location_name, arch, new_ami_id, old_ami_id
    ["us-west-2", "x64", "ami-0b0e5521b8f1b8477", "ami-0152e4e0e64ead69e"],
    ["us-east-1", "x64", "ami-0849b0e43bbfb49ad", "ami-0a3297ad5c0f9f98f"],
    ["us-east-2", "x64", "ami-0833c4b8e4a2d8c3e ", "ami-02d0ef7e8ed41ca48"],
    ["eu-west-1", "x64", "ami-073a18aa753457d32", "ami-053e00ece07d06969"],
    ["ap-southeast-2", "x64", "ami-04f85cf2853fee3bc", "ami-0673fbc45098ff3d0"],
    ["us-west-2", "arm64", "ami-0bfecdab5fba4eebd", "ami-01f9b35cfc74cc771"],
    ["us-east-1", "arm64", "ami-091301ed559682509", "ami-0baa492ac58de86cd"],
    ["us-east-2", "arm64", "ami-00cbe6d274193f377", "ami-0c79ded8114765259"],
    ["eu-west-1", "arm64", "ami-01e42a4a09da59f6b", "ami-0371bfa81d8cbbc16"],
    ["ap-southeast-2", "arm64", "ami-077bff12fce35ffd5", "ami-0035250352cebef6e"]
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
