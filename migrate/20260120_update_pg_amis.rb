# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0bd7deb9a303d5e17", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-02334466469aeb012", "ami-0baca50c6f0398ccb"],
    ["us-east-2", "x64", "ami-0fced2d13417707a1", "ami-0199d6df117801fc7"],
    ["eu-west-1", "x64", "ami-0b8df9173cf9368f1", "ami-04e410455af2701a7"],
    ["ap-southeast-2", "x64", "ami-0d9582aab33848069", "ami-058daa4601bf9bb85"],
    ["us-west-2", "arm64", "ami-03326139e14cbe464", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-0da75f483363335bf", "ami-0ec032eb86708362d"],
    ["us-east-2", "arm64", "ami-055149f57145208d4", "ami-065754213f20865f4"],
    ["eu-west-1", "arm64", "ami-081e08cd10ca655c6", "ami-0381f44b045b93d25"],
    ["ap-southeast-2", "arm64", "ami-0960a5538edec5d98", "ami-03380543da666e424"]
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
