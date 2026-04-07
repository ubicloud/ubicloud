# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-02712bde43ba1f118", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-02d417790fa40c46e", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-033b0e3e74a28562a", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-05de3f40b809a28ce", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-03b770006a967bace", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-0c5eda5283779f702", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-00860965d4cc1c4d1", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-0026be44706d3ddaa", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-0043330497648a47f", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-07a849b56829ffc6a", "ami-00e1a84392ef33cd7"],
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
