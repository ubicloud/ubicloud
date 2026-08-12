# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-010d53641c2b9287f", "ami-069ac9df30e10c275"],
    ["us-east-1", "x64", "ami-0bd811e319dc2ce2b", "ami-017e138dffbd61f8b"],
    ["us-east-2", "x64", "ami-0230a90cc05e8f698", "ami-0f53740c1592c680a"],
    ["eu-west-1", "x64", "ami-0f603cb43d36474a1", "ami-0aacc06ea24c18495"],
    ["ap-southeast-2", "x64", "ami-0731d3f2300f73606", "ami-0dfaf1a5dd7e21d75"],
    ["us-west-2", "arm64", "ami-06d37081edad11ea9", "ami-0ab5e59e896c6522b"],
    ["us-east-1", "arm64", "ami-0de73865a0fc5c394", "ami-0d37608600dc8c835"],
    ["us-east-2", "arm64", "ami-0003652cecea35f39", "ami-0bc629f5071f95de1"],
    ["eu-west-1", "arm64", "ami-0fd7bfa51c7be900d", "ami-09cb116483b7af181"],
    ["ap-southeast-2", "arm64", "ami-0df89d755109831aa", "ami-0dce7a45189e57dad"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260812-1-0", "postgres-ubuntu-2204-x64-20260611-2-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260812-1-0", "postgres-ubuntu-2204-arm64-20260611-2-0"],
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
