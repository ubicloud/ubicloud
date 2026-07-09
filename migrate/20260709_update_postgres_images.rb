# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-069ac9df30e10c275", "ami-09c95385e724959d0"],
    ["us-east-1", "x64", "ami-017e138dffbd61f8b", "ami-02d9c8f11663125fd"],
    ["us-east-2", "x64", "ami-0f53740c1592c680a", "ami-065967467b194b8ae"],
    ["eu-west-1", "x64", "ami-0aacc06ea24c18495", "ami-06ef67f7f794ca757"],
    ["ap-southeast-2", "x64", "ami-0dfaf1a5dd7e21d75", "ami-0b7d166f441037336"],
    ["us-west-2", "arm64", "ami-0ab5e59e896c6522b", "ami-019197d6d34a6ae01"],
    ["us-east-1", "arm64", "ami-0d37608600dc8c835", "ami-052bbf09f60418ef1"],
    ["us-east-2", "arm64", "ami-0bc629f5071f95de1", "ami-0636532dfde76e59d"],
    ["eu-west-1", "arm64", "ami-09cb116483b7af181", "ami-0d753ffb713e9514a"],
    ["ap-southeast-2", "arm64", "ami-0dce7a45189e57dad", "ami-02b39fc6b7ef70d8b"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260709-1-0", "postgres-ubuntu-2204-x64-20260611-2-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260709-1-0", "postgres-ubuntu-2204-arm64-20260611-2-0"],
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
      raise Sequel::Error, "irreversible: previous GCE image name unknown" if old_name.empty?
      from(:pg_gce_image).where(arch:).update(gce_image_name: old_name)
    end
  end
end
