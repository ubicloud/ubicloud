# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    # location_name, arch, new_ami_id, old_ami_id
    ["us-west-2", "x64", "ami-0f8904e4361eb8be7", "ami-0152e4e0e64ead69e"],
    ["us-east-1", "x64", "ami-0baca50c6f0398ccb", "ami-0a3297ad5c0f9f98f"],
    ["us-east-2", "x64", "ami-0199d6df117801fc7", "ami-02d0ef7e8ed41ca48"],
    ["eu-west-1", "x64", "ami-04e410455af2701a7", "ami-053e00ece07d06969"],
    ["ap-southeast-2", "x64", "ami-058daa4601bf9bb85", "ami-0673fbc45098ff3d0"],
    ["us-west-2", "arm64", "ami-0208e2e5828df2c98", "ami-0c6359b488a9ed529"],
    ["us-east-1", "arm64", "ami-0ec032eb86708362d", "ami-0bb80e22adc550c26"],
    ["us-east-2", "arm64", "ami-065754213f20865f4", "ami-04226de158be1d778"],
    ["eu-west-1", "arm64", "ami-0381f44b045b93d25", "ami-0de6479c53ebf2f2a"],
    ["ap-southeast-2", "arm64", "ami-03380543da666e424", "ami-0235e4fbf92c90b06"]
  ]
  up do
    ami_ids.each do |location_name, arch, new_ami_id, _|
      from(:pg_aws_ami).where(aws_location_name: location_name, arch:).update(aws_ami_id: new_ami_id)
    end
  end

  down do
    ami_ids.each do |location_name, arch, _, old_ami_id|
      from(:pg_aws_ami).where(aws_location_name: location_name, arch:).update(aws_ami_id: old_ami_id)
    end
  end
end
