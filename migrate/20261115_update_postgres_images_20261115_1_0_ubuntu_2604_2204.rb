# frozen_string_literal: true

# generated-by: update-postgres-images

Sequel.migration do
  ami_ids = [
    ["ubuntu-2604", "us-west-2", "x64", "ami-093bacc4d61d0180f", "ami-021c5db35b6595aff"],
    ["ubuntu-2604", "us-east-1", "x64", "ami-025494c83b0325803", "ami-0433e85f6d86046ef"],
    ["ubuntu-2604", "us-east-2", "x64", "ami-04e18138a15251d1b", "ami-015ddaea82ddbc5bc"],
    ["ubuntu-2604", "eu-west-1", "x64", "ami-0b8db4a8dfb7e7753", "ami-0cfaa0323451053a4"],
    ["ubuntu-2604", "ap-southeast-2", "x64", "ami-0b492bde5b63ea60e", "ami-02fc50ee9e23d6362"],
    ["ubuntu-2604", "us-west-2", "arm64", "ami-0cc29db44ee7bf99b", "ami-0429a9b04e5e827bc"],
    ["ubuntu-2604", "us-east-1", "arm64", "ami-08e36d3588571b9f2", "ami-058f3b0f6af69b8cb"],
    ["ubuntu-2604", "us-east-2", "arm64", "ami-0f3c6515fb9fa5172", "ami-0ddc197914c1c3f34"],
    ["ubuntu-2604", "eu-west-1", "arm64", "ami-03cdb40f5b81be064", "ami-0316ee41f2f7dd0a1"],
    ["ubuntu-2604", "ap-southeast-2", "arm64", "ami-0fa18d7eb7e27bc75", "ami-02d98ee1832352dbf"],
    ["ubuntu-2204", "us-west-2", "x64", "ami-0d19e357271752b4d", "ami-0bc7b60a5fbb1da98"],
    ["ubuntu-2204", "us-east-1", "x64", "ami-02ff0bc2f20736e49", "ami-0716dd8a2a055701d"],
    ["ubuntu-2204", "us-east-2", "x64", "ami-096cd9fde5dc221ef", "ami-0f2186ea93f4ab6dd"],
    ["ubuntu-2204", "eu-west-1", "x64", "ami-0b07030c73a509ab1", "ami-007972222d2dd9a25"],
    ["ubuntu-2204", "ap-southeast-2", "x64", "ami-012320194781061d6", "ami-0fc5775b54fb8961b"],
    ["ubuntu-2204", "us-west-2", "arm64", "ami-0b11cc850b7193723", "ami-08933d7a0d903fcc9"],
    ["ubuntu-2204", "us-east-1", "arm64", "ami-08be206ad612df6fe", "ami-0c328f83eda3af759"],
    ["ubuntu-2204", "us-east-2", "arm64", "ami-01cadd81780946f6b", "ami-07e672cc4e2cf350b"],
    ["ubuntu-2204", "eu-west-1", "arm64", "ami-0ede778f625dce333", "ami-0f0d59f1fc8e287ad"],
    ["ubuntu-2204", "ap-southeast-2", "arm64", "ami-0cd3ade7e2e028a46", "ami-0e402d99468fb6f83"],
  ]
  gce_images = [
    ["ubuntu-2604", "x64", "postgres-ubuntu-2604-x64-20261115-1-0", "postgres-ubuntu-2604-x64-20261114-1-0"],
    ["ubuntu-2604", "arm64", "postgres-ubuntu-2604-arm64-20261115-1-0", "postgres-ubuntu-2604-arm64-20261114-1-0"],
    ["ubuntu-2204", "x64", "postgres-ubuntu-2204-x64-20261115-1-0", "postgres-ubuntu-2204-x64-20261114-1-0"],
    ["ubuntu-2204", "arm64", "postgres-ubuntu-2204-arm64-20261115-1-0", "postgres-ubuntu-2204-arm64-20261114-1-0"],
  ]

  up do
    ami_ids.each do |family, location_name, arch, new_ami, old_ami|
      next if old_ami.empty?
      count = from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: old_ami)
        .update(aws_ami_id: new_ami)
      raise Sequel::Error, "pg_aws_ami: no #{family} row for #{location_name}/#{arch} at #{old_ami}" if count.zero?
    end

    gce_images.each do |family, arch, new_name, old_name|
      count = from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: old_name)
        .update(gce_image_name: new_name)
      raise Sequel::Error, "pg_gce_image: expected 1 #{family} row for #{arch} at #{old_name}, updated #{count}" unless count == 1
    end
  end

  down do
    ami_ids.each do |family, location_name, arch, new_ami, old_ami|
      next if old_ami.empty?
      count = from(:pg_aws_ami)
        .where(aws_location_name: location_name, arch:, family:, aws_ami_id: new_ami)
        .update(aws_ami_id: old_ami)
      raise Sequel::Error, "pg_aws_ami: no #{family} row for #{location_name}/#{arch} at #{new_ami}" if count.zero?
    end

    gce_images.each do |family, arch, new_name, old_name|
      count = from(:pg_gce_image)
        .where(arch:, family:, gce_image_name: new_name)
        .update(gce_image_name: old_name)
      raise Sequel::Error, "pg_gce_image: expected 1 #{family} row for #{arch} at #{new_name}, updated #{count}" unless count == 1
    end
  end
end
