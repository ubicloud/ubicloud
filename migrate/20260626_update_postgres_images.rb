# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-09c95385e724959d0", "ami-072d09de5306da793"],
    ["us-east-1", "x64", "ami-02d9c8f11663125fd", "ami-059eff6fb57b5aee9"],
    ["us-east-2", "x64", "ami-065967467b194b8ae", "ami-0604379a7c01e7f60"],
    ["eu-west-1", "x64", "ami-06ef67f7f794ca757", "ami-032975eb5e38da02f"],
    ["ap-southeast-2", "x64", "ami-0b7d166f441037336", "ami-065152a155d1b256c"],
    ["us-west-2", "arm64", "ami-019197d6d34a6ae01", "ami-04f3cadf4e25773da"],
    ["us-east-1", "arm64", "ami-052bbf09f60418ef1", "ami-0077451edee810fc3"],
    ["us-east-2", "arm64", "ami-0636532dfde76e59d", "ami-000ae71c45af0774c"],
    ["eu-west-1", "arm64", "ami-0d753ffb713e9514a", "ami-0065e87bb4d849653"],
    ["ap-southeast-2", "arm64", "ami-02b39fc6b7ef70d8b", "ami-0fee9c0cbe32132be"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260626-1-0", "postgres-ubuntu-2204-x64-20260611-2-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260626-1-0", "postgres-ubuntu-2204-arm64-20260611-2-0"],
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
