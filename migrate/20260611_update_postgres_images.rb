# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-072d09de5306da793", "ami-0d72b5445a4fa80d6"],
    ["us-east-1", "x64", "ami-059eff6fb57b5aee9", "ami-0ed5855faad7fc54f"],
    ["us-east-2", "x64", "ami-0604379a7c01e7f60", "ami-07dc2db4e7c9d6bcb"],
    ["eu-west-1", "x64", "ami-032975eb5e38da02f", "ami-0994e6336c187c419"],
    ["ap-southeast-2", "x64", "ami-065152a155d1b256c", "ami-0c85748caa9828f05"],
    ["us-west-2", "arm64", "ami-04f3cadf4e25773da", "ami-012f056b3fd40f0c0"],
    ["us-east-1", "arm64", "ami-0077451edee810fc3", "ami-0be43b9ee6a10388b"],
    ["us-east-2", "arm64", "ami-000ae71c45af0774c", "ami-0fd1d8695852c5b18"],
    ["eu-west-1", "arm64", "ami-0065e87bb4d849653", "ami-0f34cfe3c2568bee7"],
    ["ap-southeast-2", "arm64", "ami-0fee9c0cbe32132be", "ami-0d88671805843b783"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260611-2-0", "postgres-ubuntu-2204-x64-20260429-1-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260611-2-0", "postgres-ubuntu-2204-arm64-20260429-1-0"],
  ]

  up do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
    end

    gce_images.each do |arch, new_name, _old_name|
      from(:pg_gce_image).where(arch:).update(gce_image_name: new_name)
    end
  end

  down do
    ami_ids.each do |location_name, arch, new_ami, old_ami|
      from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
    end

    gce_images.each do |arch, _new_name, old_name|
      from(:pg_gce_image).where(arch:).update(gce_image_name: old_name)
    end
  end
end
