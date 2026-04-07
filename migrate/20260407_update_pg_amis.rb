# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0b23b16ee7259ecc9", "ami-0fac9c2827ce3c000"],
    ["us-east-1", "x64", "ami-06dcd9c50d48f6dcd", "ami-05dee0aaf90ceb7bb"],
    ["us-east-2", "x64", "ami-07c08dc64b785f28b", "ami-0e33685f5791249a6"],
    ["eu-west-1", "x64", "ami-0916edd1a0d31d9a6", "ami-0d2e189824fc84962"],
    ["ap-southeast-2", "x64", "ami-0501a7602279696a0", "ami-0d193b949a193ae6d"],
    ["us-west-2", "arm64", "ami-091eef44a2d734a0f", "ami-08a7683b9d8320467"],
    ["us-east-1", "arm64", "ami-0b48801b51f39761d", "ami-0b722396852594d29"],
    ["us-east-2", "arm64", "ami-0be75f8cab5e71e0c", "ami-023f659e207267d53"],
    ["eu-west-1", "arm64", "ami-0a29a3d1a2cc808d7", "ami-0df52e39fac168dc2"],
    ["ap-southeast-2", "arm64", "ami-002198e8ff04bba75", "ami-00e1a84392ef33cd7"]
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
