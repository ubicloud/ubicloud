# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    # location_name, arch, new_ami_id, old_ami_id
    ["us-west-2", "x64", "ami-05473e225fab4e082", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-0af0ecd4998635147", "ami-0baca50c6f0398ccb"],
    ["us-east-2", "x64", "ami-0251c8f07e6614ee0", "ami-0199d6df117801fc7"],
    ["eu-west-1", "x64", "ami-05258700c941ab051", "ami-04e410455af2701a7"],
    ["ap-southeast-2", "x64", "ami-0a71872beb5477073", "ami-058daa4601bf9bb85"],
    ["us-west-2", "arm64", "ami-0b47775445109ae47", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-0189adeebee0a7faf", "ami-0ec032eb86708362d"],
    ["us-east-2", "arm64", "ami-0486af6a4309ce4c1", "ami-065754213f20865f4"],
    ["eu-west-1", "arm64", "ami-0af0ac9daba46551f", "ami-0381f44b045b93d25"],
    ["ap-southeast-2", "arm64", "ami-0929767a18ba987f0", "ami-03380543da666e424"]
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
