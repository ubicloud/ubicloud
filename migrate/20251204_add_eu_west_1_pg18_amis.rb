# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_aws_ami (id, aws_location_name, arch, pg_version, aws_ami_id) VALUES
        ('9d79d347-c3f5-4b46-a034-882bf1e7b112', 'eu-west-1', 'x64', '18', 'ami-053e00ece07d06969'),
        ('ea15eb22-a5e3-4b6c-9254-80f3b96b03bb', 'eu-west-1', 'arm64', '18', 'ami-0de6479c53ebf2f2a')
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE id IN ('9d79d347-c3f5-4b46-a034-882bf1e7b112', 'ea15eb22-a5e3-4b6c-9254-80f3b96b03bb');
    SQL
  end
end
