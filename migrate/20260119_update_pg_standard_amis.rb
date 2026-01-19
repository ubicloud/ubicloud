# frozen_string_literal: true

Sequel.migration do
  up do
    [
      ["us-west-2", "x64", "16", "ami-test-x64-uswest2"],
      ["us-west-2", "x64", "17", "ami-test-x64-uswest2"],
      ["us-west-2", "x64", "18", "ami-test-x64-uswest2"],
      ["us-east-1", "x64", "16", "ami-test-x64-useast1"],
      ["us-east-1", "x64", "17", "ami-test-x64-useast1"],
      ["us-east-1", "x64", "18", "ami-test-x64-useast1"],
      ["us-west-2", "arm64", "16", "ami-test-arm64-uswest2"],
      ["us-west-2", "arm64", "17", "ami-test-arm64-uswest2"],
      ["us-west-2", "arm64", "18", "ami-test-arm64-uswest2"],
      ["us-east-1", "arm64", "16", "ami-test-arm64-useast1"],
      ["us-east-1", "arm64", "17", "ami-test-arm64-useast1"],
      ["us-east-1", "arm64", "18", "ami-test-arm64-useast1"]
    ].each do |location_name, arch, pg_version, ami_id|
      from(:pg_aws_ami).insert(
        id: Sequel.lit("gen_random_ubid_uuid(474)"),
        aws_location_name: location_name,
        arch: arch,
        pg_version: pg_version,
        aws_ami_id: ami_id
      )
    end
  end

  down do
    raise Sequel::Error, "Manual rollback required"
  end
end
