# frozen_string_literal: true

Sequel.migration do
  up do
    [
      ["us-west-2", "x64", "16", "ami-04beb3af9a2b61e45"],
      ["us-west-2", "x64", "17", "ami-04beb3af9a2b61e45"],
      ["us-west-2", "x64", "18", "ami-04beb3af9a2b61e45"],
      ["us-east-1", "x64", "16", "ami-03798ede61a18caf4"],
      ["us-east-1", "x64", "17", "ami-03798ede61a18caf4"],
      ["us-east-1", "x64", "18", "ami-03798ede61a18caf4"],
      ["us-east-2", "x64", "16", "ami-0b950ae8f8702193b"],
      ["us-east-2", "x64", "17", "ami-0b950ae8f8702193b"],
      ["us-east-2", "x64", "18", "ami-0b950ae8f8702193b"],
      ["eu-west-1", "x64", "16", "ami-0ff8fb7ca533c6ba9"],
      ["eu-west-1", "x64", "17", "ami-0ff8fb7ca533c6ba9"],
      ["eu-west-1", "x64", "18", "ami-0ff8fb7ca533c6ba9"],
      ["ap-southeast-2", "x64", "16", "ami-0c7928bf9bf4b614f"],
      ["ap-southeast-2", "x64", "17", "ami-0c7928bf9bf4b614f"],
      ["ap-southeast-2", "x64", "18", "ami-0c7928bf9bf4b614f"],
      ["us-west-2", "arm64", "16", "ami-09c4d69087c6918c4"],
      ["us-west-2", "arm64", "17", "ami-09c4d69087c6918c4"],
      ["us-west-2", "arm64", "18", "ami-09c4d69087c6918c4"],
      ["us-east-1", "arm64", "16", "ami-03131ee20d19b210f"],
      ["us-east-1", "arm64", "17", "ami-03131ee20d19b210f"],
      ["us-east-1", "arm64", "18", "ami-03131ee20d19b210f"],
      ["us-east-2", "arm64", "16", "ami-02b0eb1d49c732cef"],
      ["us-east-2", "arm64", "17", "ami-02b0eb1d49c732cef"],
      ["us-east-2", "arm64", "18", "ami-02b0eb1d49c732cef"],
      ["eu-west-1", "arm64", "16", "ami-0ed3b1a85fb1c4faa"],
      ["eu-west-1", "arm64", "17", "ami-0ed3b1a85fb1c4faa"],
      ["eu-west-1", "arm64", "18", "ami-0ed3b1a85fb1c4faa"],
      ["ap-southeast-2", "arm64", "16", "ami-0703b5bda30c77151"],
      ["ap-southeast-2", "arm64", "17", "ami-0703b5bda30c77151"],
      ["ap-southeast-2", "arm64", "18", "ami-0703b5bda30c77151"]
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
