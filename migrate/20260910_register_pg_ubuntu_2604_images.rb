# frozen_string_literal: true

Sequel.migration do
  up do
    amis = {
      ["us-west-2", "x64"] => "ami-062a7165614bee18d",
      ["us-east-1", "x64"] => "ami-06415424650897391",
      ["us-east-2", "x64"] => "ami-0664bcab58c919dc3",
      ["eu-west-1", "x64"] => "ami-08d0f9e8bf24237bf",
      ["ap-southeast-2", "x64"] => "ami-0893a1e61400a31d5",
      ["us-west-2", "arm64"] => "ami-07cdeab86a9ae662b",
      ["us-east-1", "arm64"] => "ami-0f76a3e70a8d7d177",
      ["us-east-2", "arm64"] => "ami-0e3f3672186e413f9",
      ["eu-west-1", "arm64"] => "ami-0ebdd569743502bf8",
      ["ap-southeast-2", "arm64"] => "ami-0ca7f39d98b42428e",
    }
    versions = %w[16 17 18]
    aws_rows = amis.flat_map do |(location, arch), ami_id|
      versions.map { |version| [Sequel.function(:gen_random_ubid_uuid, 474), location, arch, version, "ubuntu-2604", ami_id] }
    end
    from(:pg_aws_ami).import([:id, :aws_location_name, :arch, :pg_version, :family, :aws_ami_id], aws_rows)

    from(:pg_gce_image).import([:gce_image_name, :arch, :pg_versions, :family], [
      ["postgres-ubuntu-2604-x64-20260824-1-0", "x64", Sequel.pg_array(versions, :text), "ubuntu-2604"],
      ["postgres-ubuntu-2604-arm64-20260824-1-0", "arm64", Sequel.pg_array(versions, :text), "ubuntu-2604"],
    ])
  end

  down do
    from(:pg_aws_ami).where(family: "ubuntu-2604").delete
    from(:pg_gce_image).where(family: "ubuntu-2604").delete
  end
end
