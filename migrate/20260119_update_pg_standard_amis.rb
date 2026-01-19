# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-test-x64-uswest2", "ami-0f8904e4361eb8be7"],
    ["us-east-1", "x64", "ami-test-x64-useast1", "ami-0baca50c6f0398ccb"],
    ["us-west-2", "arm64", "ami-test-arm64-uswest2", "ami-0208e2e5828df2c98"],
    ["us-east-1", "arm64", "ami-test-arm64-useast1", "ami-0ec032eb86708362d"]
  ]

  up do
    ami_ids.each do |location_name, arch, new_ami, _old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch: arch)
        .update(aws_ami_id: new_ami)
    end
  end

  down do
    ami_ids.each do |location_name, arch, _new_ami, old_ami|
      next if old_ami.to_s.empty?
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch: arch)
        .update(aws_ami_id: old_ami)
    end
  end
end
