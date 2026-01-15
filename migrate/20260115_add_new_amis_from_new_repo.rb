# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    # location_name, arch, new_ami_id, old_ami_id
    ["us-west-2", "x64", "ami-0cc9542d64d8e3f7d", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-019dc18445f938a5c", "ami-0baca50c6f0398ccb"],
    ["us-east-2", "x64", "ami-0ca05fea5f6176273", "ami-0199d6df117801fc7"],
    ["eu-west-1", "x64", "ami-0709c15187643e724", "ami-04e410455af2701a7"],
    ["ap-southeast-2", "x64", "ami-077396e0ba4f8d473", "ami-058daa4601bf9bb85"],
    ["us-west-2", "arm64", "ami-0419751413e57ad02", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-0a2b6df9d856b3f85", "ami-0ec032eb86708362d"],
    ["us-east-2", "arm64", "ami-0d88d38f36e084e38", "ami-065754213f20865f4"],
    ["eu-west-1", "arm64", "ami-0e655ed40469a9ec4", "ami-0381f44b045b93d25"],
    ["ap-southeast-2", "arm64", "ami-094fd811f4b42e279", "ami-03380543da666e424"]
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
