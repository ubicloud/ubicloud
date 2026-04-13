# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0d72b5445a4fa80d6", "ami-022ac113b5f22b2c2"],
    ["us-east-1", "x64", "ami-0ed5855faad7fc54f", "ami-0bc62be1b75cf5910"],
    ["us-east-2", "x64", "ami-07dc2db4e7c9d6bcb", "ami-0c96600ebd30f4f9f"],
    ["eu-west-1", "x64", "ami-0994e6336c187c419", "ami-00968ba068eba5a23"],
    ["ap-southeast-2", "x64", "ami-0c85748caa9828f05", "ami-05c3d14b2d93ee810"],
    ["us-west-2", "arm64", "ami-012f056b3fd40f0c0", "ami-01f4e1d9d91166335"],
    ["us-east-1", "arm64", "ami-0be43b9ee6a10388b", "ami-07b5ee7bf00c63369"],
    ["us-east-2", "arm64", "ami-0fd1d8695852c5b18", "ami-09e8609188a645a64"],
    ["eu-west-1", "arm64", "ami-0f34cfe3c2568bee7", "ami-0ebaa42b0a03c7002"],
    ["ap-southeast-2", "arm64", "ami-0d88671805843b783", "ami-01ed388fe9ba0f51f"],
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
