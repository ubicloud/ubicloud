# frozen_string_literal: true

Sequel.migration do
  ami_ids = [
    ["us-west-2", "x64", "ami-0f13fab80fee0e3e7", "ami-02e82031ed2430dd8"],
    ["us-east-1", "x64", "ami-079fe21ebb641869c", "ami-02ff3ac69d4df45b9"],
    ["us-east-2", "x64", "ami-0fce462d3c8b2d007", "ami-024456b38ae333a25"],
    ["eu-west-1", "x64", "ami-0ff7d1f28cbed774c", "ami-0131a0421722fcc06"],
    ["ap-southeast-2", "x64", "ami-0effc52e3be7beb63", "ami-0d4ae3bf8ddc5bbcd"],
    ["us-west-2", "arm64", "ami-00551ed9239c69c3b", "ami-0c49015eb68b7993b"],
    ["us-east-1", "arm64", "ami-048d50a462b4ca06d", "ami-0808444637a1b3d1a"],
    ["us-east-2", "arm64", "ami-06fdfb0c450ef4b93", "ami-069a09c4834d00912"],
    ["eu-west-1", "arm64", "ami-06b3cb3af9b5944a5", "ami-043ea2071d55f1b89"],
    ["ap-southeast-2", "arm64", "ami-09fa06e02140ea66e", "ami-042b781ef7e20b296"],
  ]
  gce_images = [
    ["x64", "postgres-ubuntu-2204-x64-20260904-1-0", "postgres-ubuntu-2204-x64-20260611-2-0"],
    ["arm64", "postgres-ubuntu-2204-arm64-20260904-1-0", "postgres-ubuntu-2204-arm64-20260611-2-0"],
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
