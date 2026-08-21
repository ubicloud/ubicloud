# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-02e82031ed2430dd8", "ami-010d53641c2b9287f"],
    ["us-east-1", "x64", "ami-02ff3ac69d4df45b9", "ami-0bd811e319dc2ce2b"],
    ["us-east-2", "x64", "ami-024456b38ae333a25", "ami-0230a90cc05e8f698"],
    ["eu-west-1", "x64", "ami-0131a0421722fcc06", "ami-0f603cb43d36474a1"],
    ["ap-southeast-2", "x64", "ami-0d4ae3bf8ddc5bbcd", "ami-0731d3f2300f73606"],
    ["us-west-2", "arm64", "ami-0c49015eb68b7993b", "ami-06d37081edad11ea9"],
    ["us-east-1", "arm64", "ami-0808444637a1b3d1a", "ami-0de73865a0fc5c394"],
    ["us-east-2", "arm64", "ami-069a09c4834d00912", "ami-0003652cecea35f39"],
    ["eu-west-1", "arm64", "ami-043ea2071d55f1b89", "ami-0fd7bfa51c7be900d"],
    ["ap-southeast-2", "arm64", "ami-042b781ef7e20b296", "ami-0df89d755109831aa"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260821-1-0", "postgres-ubuntu-2204-x64-20260611-2-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260821-1-0", "postgres-ubuntu-2204-arm64-20260611-2-0"],
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
