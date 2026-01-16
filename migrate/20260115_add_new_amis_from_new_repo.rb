# frozen_string_literal: true

Sequel.migration do
  ami_ids = [

    # location_name, arch, new_ami_id, old_ami_id
    ["us-west-2", "x64", "ami-0a6e1f39212d1707e", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-0791869ce8f6f1df2", "ami-0baca50c6f0398ccb"],
    ["us-east-2", "x64", "ami-043afb7c1c766004b", "ami-0199d6df117801fc7"],
    ["eu-west-1", "x64", "ami-003765492e5bffc8e", "ami-04e410455af2701a7"],
    ["ap-southeast-2", "x64", "ami-04154f6a789792401", "ami-058daa4601bf9bb85"],
    ["us-west-2", "arm64", "ami-069f26737391c4585", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-0315239bb603039de", "ami-0ec032eb86708362d"],
    ["us-east-2", "arm64", "ami-0652a9929d4ffecdd", "ami-065754213f20865f4"],
    ["eu-west-1", "arm64", "ami-0e584389ec9a2bbdb", "ami-0381f44b045b93d25"],
    ["ap-southeast-2", "arm64", "ami-0211d9207e1408d60", "ami-03380543da666e424"]
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
